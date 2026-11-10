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

// dlmalloc for iOS. dlmalloc runs the games' sceClibMspace heaps, which live in guest memory, and
// calls abort() when it finds one damaged. That ended the whole app (Dead or Alive 5 Plus). Here the
// error is logged instead and dlmalloc carries on the way it does without abort: the failing call
// returns NULL or does nothing, so only the game is affected.

void vita3k_dlmalloc_error(int line); // modules/SceLibKernel/SceLibKernel.cpp

#define ABORT ::vita3k_dlmalloc_error(__LINE__)
#include "dlmalloc.cc"
