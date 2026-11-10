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

#include "virtual_pad.h"

#include <SDL3/SDL.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>

namespace {

std::mutex pad_mutex;
std::atomic<unsigned long long> quit_requested_ms{ 0 };
SDL_JoystickID pad_id = 0;
SDL_Joystick *pad = nullptr;

} // namespace

extern "C" {

bool v3k_pad_attach(void) {
    std::lock_guard lock(pad_mutex);
    if (pad)
        return true;

    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    // With no masks, SDL maps the buttons and axes in SDL_GamepadButton / SDL_GamepadAxis order
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = "Vita3K Touch Controls";

    pad_id = SDL_AttachVirtualJoystick(&desc);
    if (!pad_id) {
        SDL_Log("Vita3K: could not attach the touch controller: %s", SDL_GetError());
        return false;
    }
    pad = SDL_OpenJoystick(pad_id);
    if (!pad) {
        SDL_DetachVirtualJoystick(pad_id);
        pad_id = 0;
        return false;
    }
    return true;
}

void v3k_pad_detach(void) {
    std::lock_guard lock(pad_mutex);
    if (pad) {
        SDL_CloseJoystick(pad);
        pad = nullptr;
    }
    if (pad_id) {
        SDL_DetachVirtualJoystick(pad_id);
        pad_id = 0;
    }
}

void v3k_pad_set_button(int button, bool pressed) {
    std::lock_guard lock(pad_mutex);
    if (pad)
        SDL_SetJoystickVirtualButton(pad, button, pressed);
}

void v3k_pad_set_axis(int axis, float value) {
    std::lock_guard lock(pad_mutex);
    if (!pad)
        return;
    const float clamped = std::clamp(value, -1.0f, 1.0f);
    SDL_SetJoystickVirtualAxis(pad, axis, static_cast<Sint16>(clamped * SDL_JOYSTICK_AXIS_MAX));
}

void v3k_pad_release_all(void) {
    std::lock_guard lock(pad_mutex);
    if (!pad)
        return;
    for (int button = 0; button < SDL_GAMEPAD_BUTTON_COUNT; button++)
        SDL_SetJoystickVirtualButton(pad, button, false);
    for (int axis = 0; axis < SDL_GAMEPAD_AXIS_COUNT; axis++)
        SDL_SetJoystickVirtualAxis(pad, axis, 0);
}

// Milliseconds on the steady clock. Not SDL_GetTicks(): SDL's tick count restarts when SDL is
// shut down and started again, which made a fresh quit look 20 seconds old to the watchdog
static unsigned long long steady_ms() {
    const auto since_start = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<unsigned long long>(std::chrono::duration_cast<std::chrono::milliseconds>(since_start).count());
}

unsigned long long v3k_pad_now_ms(void) {
    return steady_ms();
}

void v3k_pad_request_exit(void) {
    quit_requested_ms = steady_ms();
    SDL_Event event{};
    event.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&event);
}

unsigned long long v3k_pad_quit_requested_ms(void) {
    return quit_requested_ms;
}

void v3k_pad_clear_quit_request(void) {
    quit_requested_ms = 0;
}

} // extern "C"
