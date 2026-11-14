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

#include <mutex>

// A "CPU core" token.
//
// Guest threads are normally plain host threads, so two guest threads that the
// game pinned to the same Vita core (identical single-bit affinity mask) really
// execute in parallel here, while on hardware they take turns and only switch
// when the running one blocks. Code that is only correct under that
// assumption (e.g. the SceLibFios2 worker threads, which take the
// SceFiosChunk and SceFiosScheduler lwmutexes in opposite orders) can deadlock
// when run truly in parallel.
//
// Threads that share a CoreToken run guest code and kernel calls one at a
// time: the token is taken before guest code runs and handed back whenever the
// thread leaves the "run" state (any wait, delay, suspend or exit).
struct CoreToken {
    std::timed_mutex mutex;
};
