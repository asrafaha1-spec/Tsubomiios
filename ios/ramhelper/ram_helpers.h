// Vita3K project
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

// RAM helpers (see protocol.h): C interface for the emulator and the Swift frontend

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Settings (UserDefaults): v3k.ramHelpers (on/off), v3k.ramHelpers.count (1 ... 4 helper processes)
bool v3k_ram_helpers_enabled(void);
// The helper extension is inside the app (a signer can strip extensions)
bool v3k_ram_helpers_bundled(void);
// Running inside LiveContainer (it needs "helper processes" turned on for the app)
bool v3k_ram_helpers_in_livecontainer(void);

// Backs [host, host + size) with helper memory, from the start, a chunk at a time; returns the bytes
// backed (0 when off or no helper could lend any). The range must be reserved, inaccessible memory;
// it stays inaccessible (the guest allocator opens pages as before). `last`: this is the last range of
// this boot (the helpers' job is done)
uint64_t v3k_ram_helpers_back(void *host, uint64_t size, bool last);

// Starts helpers in the background so the next boot doesn't wait for them
void v3k_ram_helpers_prepare(void);

// RAM checker
uint32_t v3k_ram_helpers_live(void);
uint64_t v3k_ram_helpers_backed(void); // bytes of guest memory backed by helpers this boot
uint64_t v3k_ram_helpers_in_use(void); // of those, bytes the game has touched
// Starts a helper if none runs and asks how much it can lend (blocks: not on the main thread)
uint64_t v3k_ram_helpers_probe(void);
// Last thing that happened, for the checker and the log; never NULL
const char *v3k_ram_helpers_status(void);

// This process
uint64_t v3k_memory_footprint(void);
uint64_t v3k_memory_available(void);
uint64_t v3k_memory_physical(void);

#ifdef __cplusplus
}
#endif
