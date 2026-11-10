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

// VitaCheat code types (github.com/r0ah/vitacheat/wiki/Code-Types):
//   $0X00 write          $4X01 compression       $5X00 copy (MOV)
//   $3X0N pointer write  $7X0N pointer compression $8X0N pointer copy
//   $AX00 ARM write      $B200 module-relative addresses
//   $C20N button pad     $DXNN condition
// X is the width: 0 = 8-bit, 1 = 16-bit, 2 = 32-bit. Cheats using anything else are listed as not
// supported and never run, so they can't corrupt a save.

#include "cheats.h"

#include <ctrl/ctrl.h>
#include <ctrl/functions.h>
#include <emuenv/state.h>
#include <io/state.h>
#include <kernel/state.h>
#include <mem/functions.h>
#include <mem/ptr.h>
#include <packages/sfo.h>
#include <patch/patch.h>
#include <util/log.h>

#include <fmt/format.h>
#include <miniz.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>

namespace fs = std::filesystem;

namespace ios::cheats {

namespace {

struct Line {
    uint16_t type = 0;
    uint32_t a = 0;
    uint32_t b = 0;
};

struct Cheat {
    CheatInfo info;
    std::vector<Line> lines;
};

struct ParsedFile {
    std::string title_id;
    std::string title;
    std::vector<Cheat> cheats;
};

struct Session {
    std::vector<Cheat> cheats;
    std::optional<Address> segments[2];
    bool segments_searched = false;
    uint64_t frames = 0;
};

std::mutex g_mutex;
std::optional<Session> g_session;

fs::path cheats_dir(const fs::path &patch_dir) {
    return patch_dir / "cheats";
}

fs::path enabled_file(const fs::path &patch_dir) {
    return patch_dir / "cheats_enabled.txt";
}

std::string trim(const std::string &text) {
    const auto start = text.find_first_not_of(" \t\r\n");
    if (start == std::string::npos)
        return {};
    const auto end = text.find_last_not_of(" \t\r\n");
    return text.substr(start, end - start + 1);
}

bool hex(const std::string &text, uint32_t &out) {
    if (text.empty() || text.size() > 8)
        return false;
    uint32_t value = 0;
    for (const char c : text) {
        value <<= 4;
        if (c >= '0' && c <= '9')
            value |= c - '0';
        else if (c >= 'a' && c <= 'f')
            value |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            value |= c - 'A' + 10;
        else
            return false;
    }
    out = value;
    return true;
}

// Whether every line of a cheat is a code type the engine runs
bool supported(const std::vector<Line> &lines) {
    if (lines.empty())
        return false;
    for (size_t i = 0; i < lines.size(); i++) {
        const unsigned hi = lines[i].type >> 12;
        const unsigned x = (lines[i].type >> 8) & 0xF;
        switch (hi) {
        case 0x0:
        case 0x4:
        case 0x5:
        case 0xA:
            if (x > 2)
                return false;
            break;
        case 0x3:
        case 0x7:
        case 0x8:
            if (x > 7)
                return false;
            break;
        case 0xB:
            // Module-relative addresses: only the main executable's segments are known here
            if (x != 2 || (lines[i].type & 0xFF) != 0 || (lines[i].a & 0xF) > 1)
                return false;
            break;
        case 0xC:
        case 0xD:
            break;
        default:
            return false;
        }
    }
    return true;
}

ParsedFile parse_file(const fs::path &path) {
    ParsedFile file;
    const std::string name = path.filename().string();
    file.title_id = name.substr(0, std::min<size_t>(9, name.size()));

    std::ifstream in(path, std::ios::binary);
    std::string version, author, line;
    Cheat *current = nullptr;
    while (std::getline(in, line)) {
        if (line.size() >= 3 && static_cast<unsigned char>(line[0]) == 0xEF && static_cast<unsigned char>(line[1]) == 0xBB)
            line.erase(0, 3);
        line = trim(line);
        if (line.empty())
            continue;
        if (line[0] == '#') {
            if (current)
                continue;
            const auto colon = line.find(':');
            if (colon == std::string::npos)
                continue;
            const std::string field = trim(line.substr(1, colon - 1));
            const std::string value = trim(line.substr(colon + 1));
            if (field == "Version")
                version = value;
            else if (field == "Code Author")
                author = value;
            else if (field == "Title")
                file.title = value;
            continue;
        }
        if (line.starts_with("_V")) {
            Cheat cheat;
            const auto space = line.find_first_of(" \t");
            cheat.info.name = space == std::string::npos ? std::string("Cheat") : trim(line.substr(space + 1));
            cheat.info.file = name;
            cheat.info.game_version = version;
            cheat.info.author = author;
            cheat.info.key = fmt::format("{}|{}|{}", name, file.cheats.size(), cheat.info.name);
            file.cheats.push_back(std::move(cheat));
            current = &file.cheats.back();
            continue;
        }
        if (line[0] == '$' && current) {
            std::istringstream fields(line.substr(1));
            std::string type, a, b;
            fields >> type >> a >> b;
            Line code;
            uint32_t type_value = 0;
            if (type.size() == 4 && hex(type, type_value) && hex(a, code.a) && hex(b, code.b)) {
                code.type = static_cast<uint16_t>(type_value);
                current->lines.push_back(code);
            } else {
                current->lines.clear();
                current->info.supported = false;
                current = nullptr; // malformed: ignore the rest of this cheat
            }
        }
    }
    for (auto &cheat : file.cheats)
        cheat.info.supported = cheat.info.supported && supported(cheat.lines);
    return file;
}

std::set<std::string> load_enabled(const fs::path &patch_dir, const std::string &title_id) {
    std::set<std::string> keys;
    std::ifstream in(enabled_file(patch_dir));
    std::string line;
    while (std::getline(in, line)) {
        const auto tab = line.find('\t');
        if (tab != std::string::npos && line.substr(0, tab) == title_id)
            keys.insert(line.substr(tab + 1));
    }
    return keys;
}

std::vector<fs::path> files_for(const fs::path &patch_dir, const std::string &title_id) {
    std::vector<fs::path> files;
    std::error_code ec;
    const fs::path dir = cheats_dir(patch_dir);
    if (!fs::exists(dir, ec))
        return files;
    for (auto it = fs::recursive_directory_iterator(dir, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec))
            continue;
        const std::string name = it->path().filename().string();
        std::string extension = it->path().extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
        if (extension == ".psv" && name.starts_with(title_id))
            files.push_back(it->path());
    }
    std::sort(files.begin(), files.end());
    return files;
}

// ---- Running cheats ----

uint32_t width_of(unsigned x) {
    return x == 0 ? 1 : x == 1 ? 2
                               : 4;
}

bool read_value(MemState &mem, Address address, uint32_t size, uint32_t &value) {
    if (address < 0x1000 || !is_valid_addr_range(mem, address, address + size))
        return false;
    value = 0;
    std::memcpy(&value, Ptr<uint8_t>(address).get(mem), size);
    return true;
}

// Writes only when the value differs, so watched memory isn't touched every frame. Returns true when
// memory changed.
bool write_value(MemState &mem, Address address, uint32_t size, uint32_t value) {
    if (address < 0x1000 || !is_valid_addr_range(mem, address, address + size))
        return false;
    uint8_t *host = Ptr<uint8_t>(address).get(mem);
    if (std::memcmp(host, &value, size) == 0)
        return false;
    std::memcpy(host, &value, size);
    return true;
}

// Follows a pointer chain: [[start] + offsets[0]] + offsets[1] ...
std::optional<Address> follow(MemState &mem, Address start, const std::vector<uint32_t> &offsets) {
    Address address = start;
    for (const uint32_t offset : offsets) {
        uint32_t pointer = 0;
        if (!read_value(mem, address, 4, pointer))
            return std::nullopt;
        address = pointer + offset;
    }
    return address;
}

uint32_t pressed_buttons(EmuEnvState &emuenv) {
    SceCtrlData2 data{};
    ctrl_get(0, emuenv, 0, &data, 1, false, true, false, false);
    return data.buttons;
}

void find_segments(EmuEnvState &emuenv, Session &session) {
    const std::lock_guard<std::mutex> lock(emuenv.kernel.mutex);
    for (const auto &[uid, module] : emuenv.kernel.loaded_modules) {
        if (!module)
            continue;
        const std::string path = module->info.path;
        if (path.ends_with("eboot.bin") || path.ends_with("EBOOT.BIN")) {
            for (int i = 0; i < 2; i++) {
                if (module->info.segments[i].size)
                    session.segments[i] = module->info.segments[i].vaddr.address();
            }
            session.segments_searched = true;
            return;
        }
    }
}

void run(EmuEnvState &emuenv, Session &session, const std::vector<Line> &lines, size_t begin, size_t end, Address base) {
    MemState &mem = emuenv.mem;
    size_t i = begin;
    while (i < end) {
        const Line &line = lines[i];
        const unsigned hi = line.type >> 12;
        const unsigned x = (line.type >> 8) & 0xF;
        const unsigned n = line.type & 0xFF;
        switch (hi) {
        case 0x0: // write
            write_value(mem, base + line.a, width_of(x), line.b);
            i++;
            break;
        case 0xA: { // ARM write: code changed, so its translation must be dropped
            const uint32_t size = width_of(x);
            if (write_value(mem, base + line.a, size, line.b))
                emuenv.kernel.invalidate_jit_cache(base + line.a, size);
            i++;
            break;
        }
        case 0x4: { // compression
            if (i + 1 >= end)
                return;
            const Line &next = lines[i + 1];
            const uint32_t count = next.type;
            for (uint32_t k = 0; k < count; k++)
                write_value(mem, base + line.a + k * next.a, width_of(x), line.b + k * next.b);
            i += 2;
            break;
        }
        case 0x5: { // copy
            uint32_t value = 0;
            if (read_value(mem, base + line.b, width_of(x), value))
                write_value(mem, base + line.a, width_of(x), value);
            i++;
            break;
        }
        case 0x3:
        case 0x7: { // pointer write / pointer compression
            const unsigned levels = std::max(1u, n);
            const size_t value_line = i + levels;
            const size_t count_line = value_line + 1;
            if (value_line >= end || (hi == 0x7 && count_line >= end))
                return;
            std::vector<uint32_t> offsets{ line.b };
            for (size_t k = i + 1; k < value_line; k++)
                offsets.push_back(lines[k].b);
            const auto target = follow(mem, base + line.a, offsets);
            const uint32_t value = lines[value_line].b;
            if (target) {
                if (hi == 0x3) {
                    write_value(mem, *target, width_of(x), value);
                } else {
                    const Line &count = lines[count_line];
                    for (uint32_t k = 0; k < count.type; k++)
                        write_value(mem, *target + k * count.a, width_of(x), value + k * count.b);
                }
            }
            i = hi == 0x3 ? value_line + 1 : count_line + 1;
            break;
        }
        case 0x8: { // pointer copy: destination chain, $88 line, source chain, $89 line
            const unsigned dst_levels = std::max(1u, n);
            size_t j = i + dst_levels;
            if (j >= end || (lines[j].type >> 8) != 0x88)
                return;
            std::vector<uint32_t> dst_offsets{ line.b };
            for (size_t k = i + 1; k < j; k++)
                dst_offsets.push_back(lines[k].b);
            const size_t src = j + 1;
            if (src >= end)
                return;
            const Line &source = lines[src];
            const unsigned src_width = ((source.type >> 8) & 0xF) >= 4 ? ((source.type >> 8) & 0xF) - 4 : x;
            const unsigned src_levels = std::max(1u, static_cast<unsigned>(source.type & 0xFF));
            const size_t src_end = src + src_levels;
            if (src_end >= end || (lines[src_end].type >> 8) != 0x89)
                return;
            std::vector<uint32_t> src_offsets{ source.b };
            for (size_t k = src + 1; k < src_end; k++)
                src_offsets.push_back(lines[k].b);
            const auto dst_address = follow(mem, base + line.a, dst_offsets);
            const auto src_address = follow(mem, base + source.a, src_offsets);
            uint32_t value = 0;
            if (dst_address && src_address && read_value(mem, *src_address, width_of(src_width), value))
                write_value(mem, *dst_address, width_of(src_width), value);
            i = src_end + 1;
            break;
        }
        case 0xB: { // following addresses are relative to a segment of the main executable
            if (!session.segments_searched)
                find_segments(emuenv, session);
            const auto &segment = session.segments[line.a & 1];
            if (!segment)
                return;
            base = *segment;
            i++;
            break;
        }
        case 0xC: { // run the next n lines while these buttons are held
            const bool held = (pressed_buttons(emuenv) & line.b) == line.b;
            const size_t block_end = std::min(end, i + 1 + n);
            if (held)
                run(emuenv, session, lines, i + 1, block_end, base);
            i = block_end;
            break;
        }
        case 0xD: { // run the next n lines if a value compares
            static constexpr unsigned widths[] = { 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2 };
            if (x > 0xB)
                return;
            uint32_t value = 0;
            bool match = false;
            if (read_value(mem, base + line.a, width_of(widths[x]), value)) {
                const unsigned op = x / 3;
                match = op == 0 ? value == line.b : op == 1 ? value != line.b
                    : op == 2                               ? value > line.b
                                                            : value < line.b;
            }
            const size_t block_end = std::min(end, i + 1 + n);
            if (match)
                run(emuenv, session, lines, i + 1, block_end, base);
            i = block_end;
            break;
        }
        default:
            return;
        }
    }
}

} // namespace

int install_database(const fs::path &patch_dir, const std::string &zip_data, std::string &error) {
    mz_zip_archive zip{};
    if (!mz_zip_reader_init_mem(&zip, zip_data.data(), zip_data.size(), 0)) {
        error = "the download is not a valid zip";
        return 0;
    }
    const fs::path target = cheats_dir(patch_dir) / "vita3k-patches";
    std::error_code ec;
    fs::remove_all(target, ec);
    fs::create_directories(target, ec);

    int written = 0;
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    for (mz_uint i = 0; i < count; i++) {
        char name[512];
        mz_zip_reader_get_filename(&zip, i, name, sizeof(name));
        const std::string entry = name;
        // <repo>-<branch>/cheat/PCSE00120.psv
        const auto slash = entry.rfind('/');
        if (slash == std::string::npos || entry.find("/cheat/") == std::string::npos || !entry.ends_with(".psv"))
            continue;
        const fs::path out = target / entry.substr(slash + 1);
        if (mz_zip_reader_extract_to_file(&zip, i, out.string().c_str(), 0))
            written++;
    }
    mz_zip_reader_end(&zip);
    if (written == 0)
        error = "no cheat files were found in the download";
    return written;
}

bool database_installed(const fs::path &patch_dir) {
    std::error_code ec;
    return fs::exists(cheats_dir(patch_dir) / "vita3k-patches", ec);
}

std::vector<CheatInfo> list(const fs::path &patch_dir, const std::string &title_id) {
    std::vector<CheatInfo> result;
    const auto enabled = load_enabled(patch_dir, title_id);
    for (const auto &path : files_for(patch_dir, title_id)) {
        for (auto &cheat : parse_file(path).cheats) {
            cheat.info.enabled = enabled.contains(cheat.info.key);
            result.push_back(cheat.info);
        }
    }
    return result;
}

std::vector<GameCheats> games(const fs::path &patch_dir) {
    std::map<std::string, GameCheats> by_title;
    std::error_code ec;
    const fs::path dir = cheats_dir(patch_dir);
    for (auto it = fs::recursive_directory_iterator(dir, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec) || it->path().extension() != ".psv")
            continue;
        const auto file = parse_file(it->path());
        auto &game = by_title[file.title_id];
        game.title_id = file.title_id;
        if (game.title.empty())
            game.title = file.title;
        game.count += static_cast<int>(file.cheats.size());
    }
    std::vector<GameCheats> result;
    for (auto &[_, game] : by_title)
        result.push_back(game);
    return result;
}

bool set_enabled(const fs::path &patch_dir, const std::string &title_id, const std::string &key, bool enabled) {
    std::vector<std::string> lines;
    {
        std::ifstream in(enabled_file(patch_dir));
        std::string line;
        const std::string entry = title_id + "\t" + key;
        while (std::getline(in, line)) {
            if (!line.empty() && line != entry)
                lines.push_back(line);
        }
        if (enabled)
            lines.push_back(entry);
    }
    std::error_code ec;
    fs::create_directories(patch_dir, ec);
    std::ofstream out(enabled_file(patch_dir), std::ios::trunc);
    for (const auto &line : lines)
        out << line << '\n';
    return static_cast<bool>(out);
}

void session_started(EmuEnvState &emuenv) {
    const std::lock_guard<std::mutex> guard(g_mutex);
    g_session.reset();
    const std::string title_id = emuenv.io.title_id;
    const auto enabled = load_enabled(emuenv.patch_path, title_id);
    if (enabled.empty())
        return;
    Session session;
    for (const auto &path : files_for(emuenv.patch_path, title_id)) {
        for (auto &cheat : parse_file(path).cheats) {
            if (!enabled.contains(cheat.info.key))
                continue;
            if (!cheat.info.supported) {
                LOG_WARN("Cheat '{}' uses a code type Vita3KiOS does not run yet, skipping it", cheat.info.name);
                continue;
            }
            if (!cheat.info.game_version.empty() && !patch_versions_equal(cheat.info.game_version, emuenv.app_info.app_version))
                LOG_WARN("Cheat '{}' was made for game version {}, this is version {}: it may not work",
                    cheat.info.name, cheat.info.game_version, emuenv.app_info.app_version);
            LOG_INFO("Cheat enabled: {}", cheat.info.name);
            session.cheats.push_back(std::move(cheat));
        }
    }
    if (!session.cheats.empty())
        g_session = std::move(session);
}

void frame(EmuEnvState &emuenv) {
    const std::lock_guard<std::mutex> guard(g_mutex);
    if (!g_session)
        return;
    // Give the game a moment to boot and set up its memory before writing to it
    if (++g_session->frames < 60)
        return;
    for (const auto &cheat : g_session->cheats)
        run(emuenv, *g_session, cheat.lines, 0, cheat.lines.size(), 0);
}

void session_ended(EmuEnvState &emuenv) {
    (void)emuenv;
    const std::lock_guard<std::mutex> guard(g_mutex);
    g_session.reset();
}

} // namespace ios::cheats
