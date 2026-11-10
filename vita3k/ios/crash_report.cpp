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

#include "crash_report.h"

#include <config/version.h>
#include <mem/functions.h>

#include <util/log.h>

#include <spdlog/spdlog.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <typeinfo>

#include <cxxabi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace ios::crash {

namespace {

// Paths kept in fixed buffers so the signal handler never allocates
std::array<char, 1024> g_report_path{};
std::array<char, 1024> g_marker_path{};
std::array<char, 256> g_current_game{};
std::array<char, 16> g_state{};
// Last memory/frame-rate check of the running game: if iOS closes the app without a crash
// (memory, a hang), the next launch logs it, so the log a user sends shows why
std::string g_detail;
std::string g_folder;
std::string g_previous_report;
std::string g_unreported_end;
std::mutex g_mutex;

std::string read_file(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

void write_marker(const char *state) {
    if (!g_marker_path[0] || !g_current_game[0])
        return;
    std::snprintf(g_state.data(), g_state.size(), "%s", state);
    std::ofstream marker(g_marker_path.data(), std::ios::trunc);
    marker << state << '\n'
           << g_current_game.data() << '\n'
           << g_detail << '\n';
}

void safe_write(int fd, const char *text) {
    if (text)
        (void)!write(fd, text, strlen(text));
}

void safe_write_hex(int fd, uintptr_t value) {
    char buffer[2 + 16 + 1];
    buffer[0] = '0';
    buffer[1] = 'x';
    for (int i = 0; i < 16; i++) {
        const unsigned digit = (value >> ((15 - i) * 4)) & 0xF;
        buffer[2 + i] = static_cast<char>(digit < 10 ? '0' + digit : 'A' + digit - 10);
    }
    buffer[18] = '\0';
    safe_write(fd, buffer);
}

const char *signal_name(int sig) {
    switch (sig) {
    case SIGABRT: return "SIGABRT (abort)";
    case SIGILL: return "SIGILL (illegal instruction)";
    case SIGTRAP: return "SIGTRAP (trap / unhandled memory access)";
    case SIGFPE: return "SIGFPE (arithmetic error)";
    case SIGSEGV: return "SIGSEGV (segmentation fault)";
    case SIGBUS: return "SIGBUS (bus error)";
    default: return "signal";
    }
}

void terminate_handler() {
    std::string what = "unknown exception";
    if (const auto exception = std::current_exception()) {
        try {
            std::rethrow_exception(exception);
        } catch (const std::exception &e) {
            int status = 0;
            char *type = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
            what = std::string(type && status == 0 ? type : typeid(e).name()) + ": " + e.what();
            std::free(type);
        } catch (...) {
        }
    }
    LOG_CRITICAL("Uncaught C++ exception: {}", what);
    write_note("Uncaught C++ exception: " + what);
    if (auto logger = spdlog::default_logger())
        logger->flush();
    std::abort();
}

} // namespace

void init(const std::string &folder) {
    g_folder = folder;
    const fs::path dir(folder);
    const fs::path report = dir / "crash-report.txt";
    const fs::path marker = dir / ".game-session";
    std::snprintf(g_report_path.data(), g_report_path.size(), "%s", report.string().c_str());
    std::snprintf(g_marker_path.data(), g_marker_path.size(), "%s", marker.string().c_str());

    std::error_code ec;
    const fs::path log = dir / "vita3k.log";
    const bool had_report = fs::exists(report, ec);
    const bool had_marker = fs::exists(marker, ec);

    std::string text;
    if (had_report) {
        text = read_file(report);
    } else if (had_marker) {
        std::ifstream file(marker);
        std::string state, game, detail;
        std::getline(file, state);
        std::getline(file, game);
        std::getline(file, detail);
        // No crash was recorded: the app was closed from the app switcher, or iOS closed it (memory, a hang).
        // That isn't worth interrupting anyone for: it is only written to the log.
        g_unreported_end = "The last session of " + (game.empty() ? std::string("a game") : game)
            + " ended without a crash (closed from the app switcher, or by iOS, e.g. for memory; state: " + state + ")";
        if (!detail.empty()) {
            g_unreported_end += ". Last check before it ended: " + detail;
            const long mib_left = std::strtol(detail.c_str(), nullptr, 10);
            if (state == "foreground" && (detail.find("memory warning") != std::string::npos || (mib_left > 0 && mib_left < 400)))
                g_unreported_end += ". Most likely iOS closed it for using too much memory";
            else if (state == "foreground" && detail.find("no new frame") != std::string::npos)
                g_unreported_end += ". The game had frozen; iOS (or the user) closed it";
        }
    }
    g_previous_report = text;

    // Keep the last session's log (the one that crashed, if any) before vita3k.log is overwritten
    if (fs::exists(log, ec))
        fs::rename(log, dir / "vita3k-previous.log", ec);

    // Kept for Settings › Report a problem, until the next crash replaces it
    if (!text.empty())
        fs::rename(report, dir / "last-crash-report.txt", ec);
    fs::remove(report, ec);
    fs::remove(marker, ec);
}

void install_terminate_handler() {
    std::set_terminate(terminate_handler);
}

void session_started(const std::string &title_id, const std::string &title) {
    const std::lock_guard<std::mutex> guard(g_mutex);
    std::snprintf(g_current_game.data(), g_current_game.size(), "%s (%s)", title.c_str(), title_id.c_str());
    g_detail.clear();
    write_marker("foreground");
}

void session_status(const std::string &detail) {
    const std::lock_guard<std::mutex> guard(g_mutex);
    g_detail = detail;
    write_marker(g_state[0] ? g_state.data() : "foreground");
}

void session_backgrounded(bool background) {
    const std::lock_guard<std::mutex> guard(g_mutex);
    write_marker(background ? "background" : "foreground");
}

void session_ended() {
    const std::lock_guard<std::mutex> guard(g_mutex);
    std::error_code ec;
    if (g_marker_path[0])
        fs::remove(g_marker_path.data(), ec);
    g_current_game[0] = '\0';
    g_state[0] = '\0';
    g_detail.clear();
}

void write_signal(int sig, uintptr_t pc, const char *image, uintptr_t offset, uintptr_t fault_addr) {
    if (!g_report_path[0])
        return;
    const int fd = open(g_report_path.data(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return;
    safe_write(fd, "Vita3KiOS crashed");
    if (g_current_game[0]) {
        safe_write(fd, " while running ");
        safe_write(fd, g_current_game.data());
    }
    // Which build wrote this: reports get passed around long after the crash (and an old
    // last-crash-report.txt was once taken for one of a newer build)
    safe_write(fd, "\nBuild: ");
    safe_write(fd, window_title);
    safe_write(fd, "\n\nSignal: ");
    safe_write(fd, signal_name(sig));
    safe_write(fd, "\nPC: ");
    safe_write_hex(fd, pc);
    safe_write(fd, " in ");
    safe_write(fd, image ? image : "?");
    safe_write(fd, " +");
    safe_write_hex(fd, offset);
    safe_write(fd, "\nFault address: ");
    safe_write_hex(fd, fault_addr);
    // The emulator's own memory handler raises a signal of its own after an access it cannot explain:
    // name that access, the signal above no longer carries it
    uintptr_t unhandled_host = 0;
    uint32_t unhandled_guest = 0;
    bool unhandled_write = false;
    last_unhandled_access(unhandled_host, unhandled_guest, unhandled_write);
    if (unhandled_host) {
        safe_write(fd, unhandled_write ? "\nUnhandled memory write at " : "\nUnhandled memory read at ");
        safe_write_hex(fd, unhandled_host);
        if (unhandled_guest) {
            safe_write(fd, " (guest address ");
            safe_write_hex(fd, unhandled_guest);
            safe_write(fd, ")");
        } else {
            safe_write(fd, " (outside guest memory)");
        }
        // Where the access came from: the backtrace below is the thread that raised the trap
        uintptr_t fault_pc = 0;
        uintptr_t fault_lr = 0;
        int si_code = 0;
        last_unhandled_code(fault_pc, fault_lr, si_code);
        const auto write_code = [fd](uintptr_t address) {
            safe_write_hex(fd, address);
            Dl_info info{};
            if (address && dladdr(reinterpret_cast<void *>(address), &info) && info.dli_fname) {
                safe_write(fd, " in ");
                safe_write(fd, info.dli_fname);
                safe_write(fd, " +");
                safe_write_hex(fd, address - reinterpret_cast<uintptr_t>(info.dli_fbase));
                if (info.dli_sname) {
                    safe_write(fd, " (");
                    safe_write(fd, info.dli_sname);
                    safe_write(fd, ")");
                }
            } else if (address) {
                safe_write(fd, " (JIT code or unknown)");
            }
        };
        safe_write(fd, "\nFaulting code: ");
        write_code(fault_pc);
        safe_write(fd, "\nCalled from: ");
        write_code(fault_lr);
        safe_write(fd, "\nsi_code: ");
        safe_write_hex(fd, static_cast<uintptr_t>(static_cast<unsigned>(si_code)));
    }
    safe_write(fd, "\n\nBacktrace:\n");
    void *frames[64];
    const int count = backtrace(frames, 64);
    backtrace_symbols_fd(frames, count, fd);
    safe_write(fd, "\n");
    close(fd);
}

void write_note(const std::string &text) {
    if (!g_report_path[0])
        return;
    std::ofstream report(g_report_path.data(), std::ios::app);
    report << "Vita3KiOS";
    if (g_current_game[0])
        report << " (" << g_current_game.data() << ")";
    report << ": " << text << "\n\n";
}

std::string take_previous_report() {
    const std::lock_guard<std::mutex> guard(g_mutex);
    if (!g_unreported_end.empty()) {
        LOG_INFO("{}", g_unreported_end);
        g_unreported_end.clear();
    }
    std::string report;
    report.swap(g_previous_report);
    return report;
}

std::string previous_log_path() {
    return (fs::path(g_folder) / "vita3k-previous.log").string();
}

} // namespace ios::crash
