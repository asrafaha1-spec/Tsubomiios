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

// VitaCheat (.psv) cheats for iOS. The community database (github.com/Vita3K/vita3k-patches, cheat/)
// is unpacked into <patch folder>/cheats, next to any .psv files the user adds there. Enabled cheats
// run once per frame on the main thread while a game is running, like VitaCheat on a real Vita.

#include <filesystem>
#include <string>
#include <vector>

struct EmuEnvState;

namespace ios::cheats {

struct CheatInfo {
    std::string key; // "<file>|<index>|<name>", stable across launches
    std::string name;
    std::string file; // .psv file name
    std::string game_version; // from the file's "# Version:" line, may be empty
    std::string author;
    bool supported = true; // false when it uses a code type this engine does not run
    bool enabled = false;
};

struct GameCheats {
    std::string title_id;
    std::string title;
    int count = 0;
};

// Replaces <patch dir>/cheats/vita3k-patches with the files from a downloaded repository zip.
// Returns the number of .psv files written.
int install_database(const std::filesystem::path &patch_dir, const std::string &zip_data, std::string &error);
bool database_installed(const std::filesystem::path &patch_dir);

std::vector<CheatInfo> list(const std::filesystem::path &patch_dir, const std::string &title_id);
std::vector<GameCheats> games(const std::filesystem::path &patch_dir);
bool set_enabled(const std::filesystem::path &patch_dir, const std::string &title_id, const std::string &key, bool enabled);

// Game session: load the enabled cheats, run them every frame, drop them at the end
void session_started(EmuEnvState &emuenv);
void frame(EmuEnvState &emuenv);
void session_ended(EmuEnvState &emuenv);

} // namespace ios::cheats
