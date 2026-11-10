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

// RAM helpers: the wire format between Vita3K and its helper extension (V3KRamHelper.appex).
//
// iOS gives every process its own memory limit, app extensions included. A helper is a copy of the
// extension running as its own process: it allocates purgeable memory, which iOS charges to the
// process that owns it, and hands it to Vita3K as shared memory. Vita3K maps it over part of the
// guest RAM, so the PS Vita's memory no longer counts against Vita3K's own limit. Several helpers
// can run at once, each with its own limit. The technique is the "RAM donor" of MeloNX (Stossy11,
// MIT licence); LiveContainer 3.8.13+ runs these extensions for apps inside it too.

#pragma once

// Memory moves in chunks of this size
#define V3K_RAM_HELPER_CHUNK (256ull * 1024ull * 1024ull)

// Principal class of the extension; Vita3K finds the extension in PlugIns by it
#define V3K_RAM_HELPER_PRINCIPAL "V3KRamHelperHandler"

// Message keys
#define V3K_RAM_KEY_OP "op"
#define V3K_RAM_KEY_SIZE "size"
#define V3K_RAM_KEY_SHMEM "shmem"
#define V3K_RAM_KEY_ERROR "error"
#define V3K_RAM_KEY_AVAILABLE "available"
#define V3K_RAM_KEY_FOOTPRINT "footprint"

// Operations
#define V3K_RAM_OP_HELLO "hello" // helper -> Vita3K, once connected
#define V3K_RAM_OP_CREATE "create" // a region of V3K_RAM_KEY_SIZE bytes, returned as V3K_RAM_KEY_SHMEM
#define V3K_RAM_OP_RELEASE "release" // drop every region (Vita3K has unmapped them)
#define V3K_RAM_OP_AVAILABLE "available" // os_proc_available_memory() of the helper
#define V3K_RAM_OP_FOOTPRINT "footprint" // phys_footprint of the helper
