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

// vkutil configures vulkan.hpp (designated initializers): include it, never vulkan.hpp directly
#include <util/app_activity.h>
#include <util/log.h>
#include <vkutil/vkutil.h>

#include <atomic>
#include <cstdint>
#include <type_traits>

namespace renderer::vulkan {

// Apple (MoltenVK): a GPU error in one command buffer (a fault or a timeout) makes the next fence
// wait, submit or present report VK_ERROR_DEVICE_LOST. With MVK_CONFIG_RESUME_LOST_DEVICE (set in
// renderer.cpp) the device keeps working, but vulkan-hpp turns the error into an exception, and the
// uncaught exception ended the whole app (Uncharted: Golden Abyss on an A15). On Apple, log it and
// carry on as if the call had finished: at worst one frame is wrong. Elsewhere it stays fatal.
// Device-lost errors in the current game session, and what to do when they keep coming (MoltenVK
// then fails every call: the game would only show a frozen picture). Set by the iOS app.
inline std::atomic<uint32_t> &device_lost_count() {
    static std::atomic<uint32_t> count{ 0 };
    return count;
}
inline std::atomic<void (*)()> &on_persistent_device_lost() {
    static std::atomic<void (*)()> callback{ nullptr };
    return callback;
}
constexpr uint32_t PERSISTENT_DEVICE_LOST_ERRORS = 20;

inline uint32_t count_device_lost(const char *where) {
    // Off screen, iOS refuses GPU work and MoltenVK calls that a lost device: the GPU did not fail,
    // so it must not end the game or change its settings
    if (!app_activity::gpu_allowed().load(std::memory_order_relaxed)) {
        static std::atomic<uint32_t> refused{ 0 };
        if (refused++ < 5)
            LOG_WARN("GPU work refused during {} while Vita3K is off screen (not counted as a GPU error)", where);
        return device_lost_count().load();
    }
    const uint32_t n = ++device_lost_count();
    if (n <= 5 || (n & (n - 1)) == 0)
        LOG_ERROR("GPU error (device lost) during {}; continuing ({} so far)", where, n);
    if (n == PERSISTENT_DEVICE_LOST_ERRORS) {
        LOG_ERROR("The GPU keeps failing: ending the game");
        if (auto callback = on_persistent_device_lost().load())
            callback();
    }
    return n;
}

template <typename F>
auto tolerate_device_lost(const char *where, F &&call) -> decltype(call()) {
    using Result = decltype(call());
#ifdef __APPLE__
    try {
        return call();
    } catch (const vk::DeviceLostError &) {
        count_device_lost(where);
        if constexpr (std::is_same_v<Result, vk::Result>)
            return vk::Result::eSuccess;
        else if constexpr (!std::is_void_v<Result>)
            return Result{};
    }
#else
    return call();
#endif
}

} // namespace renderer::vulkan
