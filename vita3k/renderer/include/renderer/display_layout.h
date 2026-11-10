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

#include <algorithm>
#include <atomic>

namespace renderer {

// Where the game picture sits in a window taller than the Vita's 960:544. Normally centred; iOS
// portrait mode puts it at the top (this many pixels down, below the status area) so the touch
// controls get the bottom half. Negative means centred.
inline std::atomic<float> &tall_window_top() {
    static std::atomic<float> top{ -1.0f };
    return top;
}

inline float tall_window_y(float window_height, float picture_height) {
    const float top = tall_window_top().load(std::memory_order_relaxed);
    if (top < 0.0f)
        return (window_height - picture_height) / 2.0f;
    return std::clamp(top, 0.0f, std::max(window_height - picture_height, 0.0f));
}

// Stretching to a portrait window would squash the picture: only stretch landscape windows there
inline bool can_stretch(float window_width, float window_height) {
    return tall_window_top().load(std::memory_order_relaxed) < 0.0f || window_width >= window_height;
}

} // namespace renderer
