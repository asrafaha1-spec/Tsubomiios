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

// iOS counterpart of android/jni/android_state.h: owns the emulator state for the lifetime of the app.
// The SwiftUI frontend (later phase) talks to the core through this layer, the same way the Android
// Kotlin UI talks to it through JNI.

#include "ios_platform.h"

#include <app/functions.h>
#include <app/session_controller.h>
#include <emuenv/state.h>
#include <util/fs.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ios {

struct SessionState {
    std::unique_ptr<EmuEnvState> emuenv;
    std::unique_ptr<app::AppSessionController> app_session_controller;
    Root root_paths;
};

SessionState &session_state();
EmuEnvState *get_emuenv();
app::AppSessionController *get_app_session_controller();

// Sets up logging, config and the emulated environment, storing everything under storage_path
bool initialize(const fs::path &storage_path);

// ---- Storage location ----
// The Vita file system (games, saves, firmware) lives in Documents/vita by default, or in a folder the
// user picked (on the device or an external drive). Inside a picked folder Vita3K uses it directly if
// it already holds Vita3K data (ux0), otherwise a "Vita3K" subfolder.
fs::path vita_root_for(const fs::path &picked_folder);
bool using_custom_storage();
std::string storage_note(); // why the custom location isn't used, if it isn't
// Moves the emulator to another location, copying firmware there when it has none. Blocking.
bool switch_storage(const fs::path &vita_root, bool custom, std::string &message);
fs::path internal_vita_root();

std::vector<app::AppEntry> list_apps();
std::optional<app::AppEntry> find_app_by_title_id(const std::string &title_id);

struct ImportResult {
    std::vector<std::string> installed;
    std::vector<std::string> failed;
};

// Installs every firmware (.PUP), archive (.vpk/.zip) and package (.pkg + optional .zrif) dropped
// into import_dir, then moves each handled file into import_dir/done or import_dir/failed.
ImportResult import_pending_files(const fs::path &import_dir);

} // namespace ios
