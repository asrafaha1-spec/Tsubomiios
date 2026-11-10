// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#include <codec/at9_file.h>

extern "C" {
#include <libatrac9.h>
}

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

namespace {
uint16_t rd16(const uint8_t *p) {
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
uint32_t rd32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
void wr16(std::vector<uint8_t> &out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v));
    out.push_back(static_cast<uint8_t>(v >> 8));
}
void wr32(std::vector<uint8_t> &out, uint32_t v) {
    for (int i = 0; i < 4; i++)
        out.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
} // namespace

bool decode_at9_file_to_wav(const std::string &input_path, const std::string &output_path) {
    std::ifstream in(input_path, std::ios::binary);
    if (!in)
        return false;
    const std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (file.size() < 12 || std::memcmp(file.data(), "RIFF", 4) != 0 || std::memcmp(file.data() + 8, "WAVE", 4) != 0)
        return false;

    const uint8_t *fmt = nullptr;
    size_t fmt_size = 0;
    const uint8_t *fact = nullptr;
    const uint8_t *data = nullptr;
    size_t data_size = 0;

    size_t pos = 12;
    while (pos + 8 <= file.size()) {
        const uint32_t size = rd32(&file[pos + 4]);
        const uint8_t *body = &file[pos + 8];
        const size_t available = std::min<size_t>(size, file.size() - (pos + 8));
        if (!std::memcmp(&file[pos], "fmt ", 4)) {
            fmt = body;
            fmt_size = available;
        } else if (!std::memcmp(&file[pos], "fact", 4) && available >= 12) {
            fact = body;
        } else if (!std::memcmp(&file[pos], "data", 4)) {
            data = body;
            data_size = available;
        }
        pos += 8 + size + (size & 1);
    }
    // fmt: format, channels, rate, bytes/s, block align, bits, cbSize, valid bits, mask, GUID(16), version, config
    if (!fmt || !data || fmt_size < 48)
        return false;

    const size_t block_align = rd16(fmt + 12);
    uint8_t config[4];
    std::memcpy(config, fmt + 44, 4);

    void *handle = Atrac9GetHandle();
    if (!handle)
        return false;
    if (Atrac9InitDecoder(handle, config) != 0) {
        Atrac9ReleaseHandle(handle);
        return false;
    }
    Atrac9CodecInfo info{};
    Atrac9GetCodecInfo(handle, &info);
    if (info.channels <= 0 || info.frameSamples <= 0 || info.framesInSuperframe <= 0 || block_align == 0) {
        Atrac9ReleaseHandle(handle);
        return false;
    }

    const size_t frame_shorts = static_cast<size_t>(info.frameSamples) * info.channels;
    std::vector<int16_t> pcm;
    pcm.reserve((data_size / block_align + 1) * info.framesInSuperframe * frame_shorts);
    std::vector<int16_t> frame(frame_shorts);
    for (size_t offset = 0; offset + block_align <= data_size; offset += block_align) {
        const uint8_t *p = data + offset;
        for (int f = 0; f < info.framesInSuperframe; f++) {
            int used = 0;
            if (Atrac9Decode(handle, p, frame.data(), &used) != 0) {
                Atrac9ReleaseHandle(handle);
                return false;
            }
            p += used;
            pcm.insert(pcm.end(), frame.begin(), frame.end());
        }
    }
    Atrac9ReleaseHandle(handle);

    // fact: total samples per channel, input overlap, encoder delay
    size_t skip = 0, total = pcm.size() / info.channels;
    if (fact) {
        skip = std::min<size_t>(rd32(fact + 8), total);
        total = std::min<size_t>(skip + rd32(fact), total);
    }
    if (total <= skip)
        return false;
    const size_t samples = total - skip;

    std::vector<uint8_t> wav;
    const uint32_t bytes = static_cast<uint32_t>(samples * info.channels * 2);
    wav.insert(wav.end(), { 'R', 'I', 'F', 'F' });
    wr32(wav, 36 + bytes);
    wav.insert(wav.end(), { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' });
    wr32(wav, 16);
    wr16(wav, 1);
    wr16(wav, static_cast<uint16_t>(info.channels));
    wr32(wav, static_cast<uint32_t>(info.samplingRate));
    wr32(wav, static_cast<uint32_t>(info.samplingRate * info.channels * 2));
    wr16(wav, static_cast<uint16_t>(info.channels * 2));
    wr16(wav, 16);
    wav.insert(wav.end(), { 'd', 'a', 't', 'a' });
    wr32(wav, bytes);
    const size_t header = wav.size();
    wav.resize(header + bytes);
    std::memcpy(wav.data() + header, pcm.data() + skip * info.channels, bytes);

    std::ofstream out(output_path, std::ios::binary | std::ios::trunc);
    if (!out)
        return false;
    out.write(reinterpret_cast<const char *>(wav.data()), static_cast<std::streamsize>(wav.size()));
    return out.good();
}
