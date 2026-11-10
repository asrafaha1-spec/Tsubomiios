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

#pragma once

// Crash reports for iOS. A crash (signal, uncaught exception, stuck quit) writes crash-report.txt next
// to the log. A game session that vanishes with no crash at all (iOS killing the app for memory, a
// watchdog kill) is detected on the next launch from a marker file. The library shows the report once,
// with the log of the session that crashed (vita3k-previous.log), so users can share it.

#include <cstdint>
#include <string>

namespace ios::crash {

// Call before the logger opens vita3k.log: keeps the previous session's log as vita3k-previous.log
// and reads what the previous session left behind.
void init(const std::string &folder);

// Installs std::terminate reporting (uncaught C++ exceptions)
void install_terminate_handler();

void session_started(const std::string &title_id, const std::string &title);
void session_backgrounded(bool background);
// Last health check of the running game (memory left, frame rate, warnings), logged on the next
// launch if the session ends without a crash report
void session_status(const std::string &detail);
void session_ended();

// Async-signal-safe: appends a crash entry with a backtrace of the crashing thread
void write_signal(int sig, uintptr_t pc, const char *image, uintptr_t offset, uintptr_t fault_addr);
// Not signal-safe: appends a free-form entry (stuck quit, ...)
void write_note(const std::string &text);

// The report left by the previous session, or an empty string. Returned once.
std::string take_previous_report();
std::string previous_log_path();

} // namespace ios::crash
