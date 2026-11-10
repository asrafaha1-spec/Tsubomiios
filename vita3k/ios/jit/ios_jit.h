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

// iOS JIT, ported from Tsubomi by 125hz (https://github.com/125hz/Tsubomi, GPL-2.0).
//
// On iOS 26+ every dynarmic code cache is an RX mapping that StikDebug's universal.js prepares
// (brk #0xf00d, see patches/0001-oaknut-ios-rwx-jit.patch), plus a writable alias. Vita3K creates a
// cache per guest thread, so a pool of them is prepared up front while StikDebug is attached.
// On older iOS the classic debugger RWX mapping is used and no preparation is needed.

#include <string>

namespace ios {

// Logs fatal signals (with PC and image) and turns an unanswered JIT breakpoint into a failed
// allocation instead of a crash
void install_fatal_signal_logger();

bool debugger_attached(); // P_TRACED: a debugger is attached right now
bool jit_capability_enabled(); // CS_DEBUGGED or attached
bool jit_available(); // pool prepared, or a debugger is attached to prepare one
bool jit_pool_ready();
bool jit_can_prepare(); // JIT is enabled and the pool can be prepared now

// Reserves guest memory, then prepares the JIT region pool. Blocks while StikDebug works.
bool prepare_jit_pool();

std::string jit_status_text();

// Regions prepared so far / regions wanted, for the UI
int jit_pool_progress();
int jit_pool_target();
// Prepared code caches currently free (iOS 26 pool); -1 when there is no pool (older iOS)
int jit_pool_available();

} // namespace ios
