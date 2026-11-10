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

// In-game extras driven from the touch overlay: screenshots to Photos, the rear touchpad, and
// keeping the motion sensors lined up with the landscape screen. The overlay only sets requests;
// they are carried out once per frame on the main thread (the SDL loop), where the emulator state
// may be touched.

struct EmuEnvState;

namespace ios::extras {

void session_started(EmuEnvState &emuenv);
void frame(EmuEnvState &emuenv);
void session_ended(EmuEnvState &emuenv);

} // namespace ios::extras
