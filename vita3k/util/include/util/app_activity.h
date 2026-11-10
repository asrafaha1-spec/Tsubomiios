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

#include <atomic>

// Whether the app may use the GPU right now. iOS refuses GPU work from an app that is not on screen
// (the command buffer fails and MoltenVK reports the device as lost), so the iOS app clears this as
// soon as it stops being active (home screen, app switcher, Control Center, a call) and sets it again
// once it is active. Always true elsewhere.
namespace app_activity {

inline std::atomic<bool> &gpu_allowed() {
    static std::atomic<bool> value{ true };
    return value;
}

} // namespace app_activity
