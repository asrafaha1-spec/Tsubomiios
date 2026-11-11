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

// RAM helpers: writes to vita3k.log for ram_helpers.mm (util/log.h clashes with Foundation there)

#include <util/log.h>

extern "C" void v3k_ram_helpers_log(bool warning, const char *message) {
    if (warning)
        LOG_WARN("RAM helpers: {}", message);
    else
        LOG_INFO("RAM helpers: {}", message);
}
