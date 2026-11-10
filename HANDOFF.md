# Vita3KiOS: handoff notes

Everything the previous assistant knew about this project, for whoever picks it up next. Current as of
the commit that raised the JIT pool to 64 (4 Nov 2026). Last published release: **v1.1.0** (4 Nov 2026, commit `ec155e73`). The release run's
AltStore push hit a GitHub 500, so `dist/altstore/source.json` was updated by hand (build 76).
- A later re-run of the release workflow (to change the notes) was cancelled mid-way. Its
  `gh release upload --clobber` had already deleted the IPA, so the owner re-uploads
  `Vita3KiOS-1.1.0.ipa` (build 76) by hand. The release notes were also replaced by hand, with no
  game names in them; the owner asked for that.
- Lessons for releases:
  - Assistant sessions may not be able to create or edit releases through the API (403). Change
    release notes by giving the owner the text, not by re-running the workflow.
  - Never cancel a release run mid-way.

---

## 1. Project

- **What it is:** an iOS fork of Vita3K, the PS Vita emulator.
- **Repo:** `oledz-i/Vita3KiOS` on GitHub, branch `main`. Remotes: `origin`/`github` (this fork) and
  `upstream` (`Vita3K/Vita3K`).
- **Built from:** Vita3K, Tsubomi (by 125hz, an earlier iOS port; several iOS pieces come from it),
  dynarmic/oaknut (CPU JIT), MoltenVK (Vulkan on Metal) and SDL3.
- **JIT:** comes from StikDebug, which attaches a debugger. Apps also run inside LiveContainer or
  SideStore. StikDebug and LiveContainer are not credited (they are tools users run, not things the
  app is built from).
- **Test device:** the owner uses an iPhone 16 (`iPhone17,3`, A18 GPU, iOS 26.5.2), with SideStore +
  LiveContainer and StikDebug.
- **Community and support:**
  - Discord: https://discord.gg/pZyQDPHKF
  - Ko-fi: https://ko-fi.com/Oledz
  - Both are in the README badges and Support section, in Settings › About, and in
    `.github/FUNDING.yml`, which also keeps upstream Vita3K's Ko-fi.

### Fixed rules from the owner
- Bundle ID stays `org.vita3k.ios`.
- Plain unsigned IPA built by `xcodebuild` in GitHub Actions. No TrollStore build.
- **Never release without the owner's explicit OK.** Pushing to `main` builds a test IPA. That is fine.
- **Releases:**
  - Only the IPA. Versions follow the app (v1.0.0 → next would be 1.0.1 or 1.1.0, as the owner
    chooses).
  - The workflow updates the AltStore/SideStore source on its own.
- **Every update should bring a noticeable performance gain**, even a small one.
- **Landscape touch layout must stay UNTOUCHED.** Portrait has its own layout.
- **Controller themes:** the Xbox theme uses letters (A/B/X/Y).
- **Credits:** only what the app is built from (Vita3K, Tsubomi by 125hz, dynarmic/oaknut, MoltenVK,
  SDL). No StikDebug or LiveContainer in credits.
- **Commits and PRs:**
  - No bare `@name` in commit messages or PR bodies.
  - End commit messages with the attribution lines your own session gives you.
- The owner's email address is not to be sent anywhere.
- **Reporting to the owner:**
  - The owner is direct and gets frustrated with repeated Madden failures.
  - Be honest about what is verified (built in CI) versus untested on a device. Never claim a fix
    works on the phone without a log showing it.
  - Short reports work best: what was wrong, what changed, what is still unknown, what log to send.

---

## 2. Build, CI, release

- **Workflows** (`.github/workflows/`):
  - `ios.yml` builds the IPA.
  - `format.yml` runs clang-format **22**.
  - Also present: CodeQL, c-cpp and labeler.
- **`ios.yml` triggers:**
  - Push to main. paths-ignore: `**.md`, `dist/altstore/**`, `dist/readme/**`, `dist/game-fixes.txt`.
  - Tags `v*`.
  - `workflow_dispatch` with a `release` input (e.g. `1.0.1`) and optional notes.
- **Release:**
  - Run the workflow with `release=X.Y.Z`, or push tag `vX.Y.Z`.
  - It builds, creates the GitHub release with the IPA (`Vita3KiOS-X.Y.Z.ipa`), and commits the
    updated `dist/altstore/source.json` (via `.ci/altstore-source.py`).
  - Release notes are generated from commit subjects since the previous tag.
  - The app version comes from `VITA3KIOS_VERSION`. Without a release the default is 1.0.0.
- `[skip ci]` in a commit message skips builds.
- **CI quirks:**
  - macOS runners sometimes never start and the run is cancelled after ~15 min. Fix:
    `gh run rerun <id> -R oledz-i/Vita3KiOS`.
  - Watch a commit's runs:
    `gh api "repos/oledz-i/Vita3KiOS/actions/runs?head_sha=$(git rev-parse HEAD)" --jq '.workflow_runs[] | "\(.name) \(.status) \(.conclusion)"'`.
  - Failed build errors:
    `gh run view <id> -R oledz-i/Vita3KiOS --log-failed | grep -E "error:"`.
  - The GraphQL `gh release view` was blocked in the old session; the REST `gh api repos/.../releases`
    works.
- **Local formatting:** only clang-format 18 was available locally; CI uses 22. They disagree on
  `struct X y {}` spacing: write `y{}` (e.g. `struct sigaction sa{}`). Check all changed files with
  `clang-format-18 file | diff file -` before pushing.
- **No local iOS build:** the old environment was Linux. Every change was compile-checked only by
  CI. Mind declaration order: a helper used before it is defined broke a build once.
- **MoltenVK:** v1.4.1, linked statically. It is downloaded by `external/CMakeLists.txt`
  (`MoltenVK-ios.tar`).
- **Deployment target:** iOS 17.4.

---

## 3. Where things are

### iOS app (`vita3k/ios/`)
- **`main_ios.cpp`:**
  - App entry and the per-game session loop.
  - Watchdog thread: memory/frame log every 10 s, notes "phone hot", force-exits 20 s after Quit
    without writing a crash report.
  - Device-lost handling.
  - Portrait unlock.
  - Pause API: `v3k_set_game_paused`, `v3k_game_paused_by_user`.
  - MoltenVK env vars.
  - Sets `thermal::keep_cool`.
- **`ios_platform.{h,mm}`:**
  - Background tracking.
  - Thermal state observer, which sets `thermal::phone_is_hot`.
  - `keep_cool_enabled`, `portrait_mode_enabled`, `interface_rotation`.
  - Save to Photos.
  - SDL scene-delegate swizzles (launch links `vita3k://`, quick actions, "Open in Vita3K" imports).
- `ios_session.cpp`: logging init, etc.
- `crash_report.cpp`: signal/terminate handlers. Writes `crash-report.txt`; the previous one is kept
  as `last-crash-report.txt`.
- **`jit/ios_jit.cpp`:**
  - JIT region pool: `IOS_JIT_POOL_TARGET = 64` regions × 16 MiB, prepared in one StikDebug request
    at launch.
  - When the pool runs out, `create_thread` fails and the game gets `SCE_KERNEL_ERROR_NO_MEMORY`.
    The app does not crash.
- `patches/0001-oaknut-ios-rwx-jit.patch`: oaknut patch for the JIT region pool. Editing it means
  fixing hunk line counts.
- `game_extras.{h,cpp}`: screenshot, rear touchpad, motion rotation, `v3k_set_portrait_top`.
- `cheats.cpp`: cheats.
- **`bridge/vita3k_bridge.{cpp,h}`:**
  - C API used by Swift: settings JSON and setters, per-game settings, game fixes, compat DB, the
    problem-report zip, session messages, launch/import requests.
  - Per-game setters live in `v3k_set_game_setting`; global ones in `v3k_set_setting_bool/string`.
- `controls/virtual_pad.{h,cpp}`: virtual gamepad, the quit request (steady clock, *not*
  SDL_GetTicks) and pause declarations.
- **`ui/*.swift`** (SwiftUI and UIKit):
  - `LibraryView`, `LibraryModel`, `LibraryHost`: library, launch, imports, quick actions,
    migrations.
  - `SettingsView`, `GameSettingsView`: settings screens.
  - `TouchControls.swift`: on-screen controls, game menu, pause button and Paused banner, layout
    editor, `PortraitMode`, `ControlsViewController`.
  - `PerformanceHUD.swift`: FPS / RAM / thermal overlay.
  - `MenuMusic`, `AnimatedBackground`.
  - The Swift↔C bridging header is `ui/Vita3K-Bridging-Header.h`.
- `Info.plist.in`:
  - Photo and motion usage strings.
  - URL scheme `vita3k`.
  - Document types: vpk, pkg, pup, zip (as Alternate).
- **`ios_target.cmake`:** sources, frameworks and the deployment target. New iOS files must be added
  here.

### Emulator core changes that matter on iOS
- **`app/src/app_init.cpp`:**
  - Game fixes: `DEFAULT_GAME_FIXES`, `find_game_fix`, `apply_fix_setting`,
    `apply_builtin_game_fixes`.
  - `apply_required_game_settings`, which applies even with custom settings: Madden async shaders
    on, Madden CPU optimisations on, FSR → Bilinear.
  - Shutdown sequence with timing logs.
  - The "Game settings:" log line.
- **`renderer/src/vulkan/`:**
  - `renderer.cpp`:
    - MoltenVK layer settings: full image view swizzle, resume lost device, async queue submits,
      concurrent compilation, fast math (precise via `V3K_PRECISE_SHADER_MATH=1`).
    - **Semaphore style 0** (single queue) and **shader compression LZFSE**.
    - Memory mapping methods and `map_memory`.
  - `screen_renderer.cpp`: swapchain, 1 s acquire and fence timeouts on Apple, semaphores renewed on
    rebuild.
  - `context.cpp`: the frame fence waits are abortable.
  - `pipeline_cache.cpp`:
    - Async compile workers (≥4 on iOS).
    - `failed_pipeline()` marker when Metal refuses a pipeline; its draws are skipped.
    - Damaged cache files are deleted.
    - The cache is not saved after device lost.
    - Atomic tmp+rename save.
    - Metal vertex layout helpers.
  - `scene.cpp`: triangle fans → lists, odd-stride restride/repack, vertex layout diagnostics.
  - `device_lost.h` (`renderer/include/renderer/vulkan/`):
    - `tolerate_device_lost` catches `vk::DeviceLostError` on Apple.
    - `count_device_lost`; after 20 errors the game is closed through a callback.
    - Include it via `vkutil.h`, never `vulkan.hpp` directly.
- **`renderer/src/batch.cpp`:**
  - The render loop.
  - The precompile progress bar is throttled to 30 fps.
  - **While paused, no GPU work at all.** iOS kills apps that use the GPU in the background.
- `renderer/include/renderer/display_layout.h`: `tall_window_top`, `tall_window_y`, `can_stretch`
  for portrait.
- **`mem/src/mem.cpp`:**
  - Write-protection tracking. Host pages are **16 KiB on Apple silicon**.
  - `align_to_page`; `release_host_page`, which notifies the segments sharing a page that has to be
    unprotected.
  - External mappings for page-table mode.
- **`kernel/src/kernel.cpp`:**
  - Guest threads use `thermal::game_thread_qos()`.
  - `process_exit` waits 5 s then leaves stuck threads (iOS).
  - Upstream fix: threads created during exit also end.
- `util/include/util/thermal.h`: `keep_cool`, `phone_is_hot`, `game_thread_qos`, `follow_render_qos`.
- `dist/game-fixes.txt`: the downloadable fixes list (format explained in its header). It is cached at
  `cache_path/game-fixes.txt`; `DEFAULT_GAME_FIXES` is the offline fallback.

---

## 4. How features work

### Game fixes
- **Built-ins:** `apply_builtin_game_fixes` applies them only when the game has **no** custom config.
  The downloaded list then overrides them. Games with custom settings get a "Use recommended
  settings" button (`v3k_apply_game_fix`). The label says "applied" when the settings already match
  (`matches` in `v3k_game_fix_json`).
- **Keys:**
  - On/off keys: memory-mapping, native-buffer, surface-sync, high-accuracy, async-shaders,
    texture-cache, shader-cache, fps-hack, cpu-opt, v-sync, stretch, fast-cpu.
  - Valued keys: resolution=X, screen-filter=Name.
  - `fast-cpu` is read on the Swift side per game (`v3k_game_fix_flag`).
- **Current fixes:**
  - Gravity Rush PCSA00011/PCSF00024: surface sync on (fixes the over-bright bloom; Vita3K
    compatibility issue #177).
  - Persona 4 Golden PCSE00120/PCSB00245: memory mapping off. It fixed vertex spikes; the owner found
    this.
  - Madden NFL 13 PCSE00084: mapping on (double buffer), surface sync off, async shaders on, Fast CPU
    off.
  - Disgaea 3: JIT pool raised from 32 to 48.

### Memory mapping and Native buffer
- Methods: `disabled`, `double-buffer` (default), `page-table`. `external-host` is refused on iOS
  because the host pointer alignment is 16K > 4K. Android's `native-buffer` doesn't exist on iOS.
- **"Native buffer"** in the UI = Vita3K's **page-table** mapping (`memory_mapping: page-table`):
  - CPU and GPU share pages. The CPU goes through a page table (a bit slower; no fastmem).
  - With CPU optimisations off, dynarmic gets no page table at all and every access is a callback
    (very slow).
  - The mapped buffer is a dedicated VMA allocation, placed at the same offset within a 16K host page
    as the guest address (fix in 6365ba1f).
- Surface sync needs memory mapping on Vulkan.
- When the GPU fails 20 times (device lost) the game is closed. On the next run the app turns
  background shaders on, or turns mapping off unless the game's fix needs it.

### Portrait mode (`v3k.portraitMode`, default on)
- Games boot in landscape. `main_ios` `on_frame` unlocks portrait 2 s after the first game frame
  (`SDL_HINT_ORIENTATIONS` + `v3k_set_portrait_unlocked`), and turns to portrait at once if the phone
  is upright.
- Why: booting upright stalled the GPU for ~5 s, then device lost (Madden, P4G). Rotating during play
  works. Root cause not found.
- The game picture sits at the top (`v3k_set_portrait_top` from `layoutPortrait`). The controls get
  the bottom, with a separate placements key `v3k.touchLayout.portrait`.

### Last build (ab84ea4f)
- **Memory mapping is one picker:** Double buffer / Native buffer (page-table) / Off.
  - Global setting key: `memory-mapping-mode` via `v3k_set_setting_string`.
  - Per-game: same key via `v3k_set_game_setting`.
  - JSON field: `mappingMode`.
  - Swift enum `MemoryMappingMode` in `GameSettingsView.swift`.
- **Background cache saves:** periodic pipeline cache saves run on a background thread
  (`save_pipeline_cache(true)`, `cache_save_thread`). Exit, background and cleanup saves still run
  synchronously after joining.
- **Texture cache:** `TextureCacheSize` is 2048 on iOS (1024 upstream).

### Pause (46fafde3)
- The top-bar pause button, and Pause/Resume in the game menu, use `v3k_set_game_paused(1, …)`.
- The game menu and the Quit prompt pause the game while open (`reason 2`). Each action calls
  `menuClosed()`. Quit unpauses, then requests exit.
- Pausing stops guest threads and audio, drops input, and `renderer.paused` makes the render loop
  sleep.

### Thermal ("Keep the phone cool", `v3k.keepCool`, default on)
- Guest threads run at QoS USER_INITIATED instead of USER_INTERACTIVE.
- When iOS thermal state is serious or critical, the render loop, GPU-wait thread, vblank and display
  thread step down to USER_INITIATED.

### Other UI features already shipped
- **Library:** compatibility badges (Vita3K compat DB, downloaded daily), quick actions, Add to Home
  Screen links (`vita3k://`), Open in Vita3K for vpk/pkg/zip.
- **Settings:** Report a problem (zip of logs, crash reports, device info and custom configs),
  system language and confirm button, shader/texture options, surface sync (off by default; a
  migration flag turns it back off).
- **Game menu:** screenshots to Photos, rear touchpad toggle, layout editor (drag/pinch),
  show/hide controls.
- **Per game:** precise shader math.
- Performance HUD.
- **FSR is not offered:** the swapchain isn't an RGBA8 storage image. Stale FSR settings are shown
  and run as Bilinear.

---

## 5. Lessons learned (do not repeat)

- **Copying every vertex stream on the CPU** (full Metal repack, b525ade) broke Persona 4 Golden's
  3D: it reads GPU-written data through mapping. It was reverted. Only odd-stride streams are
  realigned now (`metal_stream_layout`: repack only if stride%4≠0 and some offset%4≠0).
- **Surface sync on by default** crashed Madden at boot (memory access storm) and blacked out the
  field. It was reverted to off.
- **Precise shader math** did not fix Gravity Rush; surface sync did.
- Metal has no triangle fans: they are expanded to lists. Vertex strides must be multiples of 4.
- **Unbounded GPU waits** (acquire, fences) froze games and blocked Quit. They are now 1 s steps on
  Apple.
- **SDL_GetTicks restarts when SDL re-initialises.** The Quit watchdog used it and killed the app
  after every clean exit. It now uses the steady clock.
- **The pipeline cache saved after a device lost** was rejected on every later boot
  (`createPipelineCache: ErrorInitializationFailed`), and the game crashed at boot.
  - Now caught: a damaged file is deleted.
  - The cache is not saved after GPU errors.
  - Writes are atomic.
- **vulkan-hpp throws** from `createGraphicsPipeline` when Metal refuses a shader (One Piece Burning
  Blood). Uncaught on a compile thread it aborted the app. It is now caught and the draws are
  skipped.
- **The precompile progress bar drew a frame per shader** (hundreds of presents per second at boot).
  It is throttled to 30 fps.
- **The renderer kept drawing while paused** and in the background. iOS kills background GPU users
  ("crashes when you leave for a bit"). It is now fully idle when paused.
- **16 KiB host pages** break any code assuming 4 KiB `mprotect` granularity. Protections must be
  host-page aligned, and page-table buffers must be host-page congruent. Look for
  "Unhandled/Write to a protected host page" in logs.
- **`include <vulkan.hpp>` directly** (without vkutil's defines) broke designated initializers.
- **iOS-only APIs** in shared code were declared Android-only (`set_rear_touchscreen`,
  `set_display_rotation`). Extend those `#if`s to `VITA3K_PLATFORM_IOS`.

---

## 6. Open issues (most important first)

1. **Madden NFL 13 (PCSE00084):**
   - Vita3K's compatibility list rates it **"In game −", graphics bug** (compatibility issue #1328),
     including on PC.
   - Seen on iOS:
     - Faces and bodies break up without memory mapping.
     - Stray giant triangles in menus and black/missing stadium stands. The last log used Native
       buffer and had 101 unhandled protect faults; fixed in 6365ba1f but **untested on a device**.
     - Earlier, 5 s GPU hangs at boot. Two causes: shaders compiled before drawing (now forced
       async), and booting upright (now boots landscape).
     - The owner's per-game config had CPU optimisations off, giving ~21 FPS. Now forced on.
   - **Next step:** get logs with Native buffer on and off from this build and compare.
2. **Booting a game upright stalls the GPU.** It is worked around by landscape boot; the root cause is
   unknown. It is not semaphores (single-queue style didn't fix it) and not the swapchain rebuild.
   Candidates: something in the first frames with a portrait swapchain, or the precompile overlay in
   portrait.
3. **Persona 4 Golden:**
   - The street/ground renders white in a rainy "Early Morning" scene. Suggested test: per-game
     Precise shader math. Unconfirmed.
   - The hang on the way to school was really the rotation freeze (fixed).
4. **One Piece Burning Blood (PCSE00808):** Metal rejects a shader. It no longer crashes (draws
   skipped), but the cause needs a `vita3k.log`, which names the shader hashes.
5. **Street Fighter X Tekken:** a user on iOS 27 / iPhone 12 crashed earlier (device lost path).
   It is mitigated, unverified.
6. **RAM:** ~2.2–2.6 GB in play. The JIT pool reserves 768 MiB of address space. A possible future
   option is `madvise` on returned JIT regions, but it is risky with StikDebug-prepared memory.
7. **Thermals:** "Serious" in Persona and Madden even after Keep cool. Further levers: frame pacing,
   fewer guest threads at high QoS, lower internal resolution when hot.
8. Madden: per the owner, Native buffer did not fix the deformed face skin (features in place, skin
   misplaced), and the stadium jumbotron is black.
   - Log ff430259 (Native buffer, build 6365ba1): the unhandled protect faults are gone.
   - 4592fec7 decodes texture offsets inside tiled/swizzled render targets correctly. They used the
     linear formula. The theory is that the face skin is a self-drawn atlas, but this is unconfirmed.
   - 4592fec7 also logs `Texture inside a ... render target` and `overlaps a render target but is
     not taken from it: <reason>`. Use those lines from the next Madden log to chase the face and the
     jumbotron.
   - Suggested owner test: Surface sync on for Madden. It crashed at boot before the 16K protection
     fixes; it may work now and is the usual fix for black render-to-texture.
9. Mortal Kombat 9: reported crashing, no log yet.
   - Dead or Alive 5 Plus (PCSE00235): `std::bad_alloc` in `oaknut::CodeBlock` because the JIT pool
     (then 32) was exhausted. The game had 37 threads at boot, on an iPhone16,2 with iOS 27.2 and
     build v1.0.0. The pool is now 64, and newer builds also turn pool exhaustion into
     `SCE_KERNEL_ERROR_NO_MEMORY` for the game instead of a crash.
   - Madden face ("melting putty") in log 122cc30c: no `Texture inside`/`not taken from it` lines, so
     it is most likely a geometry problem (vertex/bone data), not render-to-texture. Untested
     candidates: facial bones in a uniform buffer region, vertex attribute formats, and Metal fast
     math. Quick owner test: Precise shader math on. The jumbotron also never overlapped a render
     target in that log.
   - 48268c90: the surface sync + high accuracy crash was a write to unallocated guest memory
     (0xFF000A0C). On iOS that page now gets zeroed memory instead of crashing. Madden's
     recommended settings are now Native buffer + surface sync on + high accuracy off; the owner
     reports surface sync boots with Native buffer. The face is still not fixed.
   - b2e01e04: a best-guess face fix, "Accurate CPU" (`set_ios_accurate_cpu`,
     game-fix key `accurate-cpu=on`, on for Madden). Dynarmic runs without the IR optimisations
     ConstProp, GetSetElimination and MiscIROpt; block linking, the return stack buffer and fast
     dispatch stay. The theory is that the CPU-side face animation math is mis-optimised.
     - It did not fix the face, so `accurate-cpu=on` was removed from Madden's fix. The mode
       still exists for other games. The next suspects are uniform buffer bone ranges and vertex
       formats. Precise shader math
     and high accuracy were tried; the effect on the face was not reported.
   - Earlier: Madden crashes with surface sync on (SIGTRAP from the memory handler). Since 14dc39ed the crash
     report names the faulting address (read/write, guest address or "outside guest memory"). A
     crash report from the new build is needed.
10. Unverified on a device: the pause feature, portrait unlock flow, Native buffer fixes, darker
   controls (all from 3–4 Nov).

---

## 7. Reading a user log fast

- **First lines:** `Vita3K v0.2.1 1-<commit>` tells you the build; then `Device:` and `OS:`.
- **`Game settings: …`** tells you the effective per-game settings (resolution, filter, memory
  mapping, async shaders, surface sync, CPU optimisations, V-Sync).
- **`Launching <ID>` / `Game started` / `Shutting down game` / `exited with code`** mark session
  boundaries.
- **`Motion sensors: screen rotation 0°`** means the phone was upright; 90° means landscape.
- **`count_device_lost` / `The GPU keeps failing`** means the GPU failed (Metal timeout or fault).
  Check the ~5 s silence before it.
- **`Could not wait for fences`** means a frame did not finish within 1 s (GPU stall).
- **`Watchdog: … frames, phone hot`** shows memory left and the frame counter; 0 for long means
  frozen.
- **`Unhandled write protected` / `Write to a protected host page`** points to a write-tracking
  problem (stale textures and buffers).
- **`Metal vertex layout check` / `Realigning vertex attributes`** marks odd vertex formats.
  Attribute format numbers: U8=0, S8=1, U16=2, S16=3, U8N=4, S8N=5, U16N=6, S16N=7, F16=8, F32=9.
- **`The GPU driver could not build a pipeline`** means Metal refused a shader; the line names the
  hashes.
- **Crash reports:** the first line says the reason (signal or uncaught exception). The backtrace
  names the Vita3K function.

### Useful one-liners
```sh
grep -F -e "|E|" -e "|W|" -e "|C|" vita3k.log | grep -v "open_dir\|open_file\|io_error" | cut -c16- | sed 's/0x[0-9A-Fa-f]*/X/g' | sort | uniq -c | sort -rn | head -40
grep -n "Launching\|Game settings\|rotation\|device lost\|GPU keeps\|exited" vita3k.log
```

---

## 8. Upstream

- `git fetch upstream master`; `git log HEAD..upstream/master` shows what is new.
- Cherry-pick small fixes. aca188ee (threads created during exit) was taken.
- Avoid the big CPU refactors (81085af7, d8329f2b) unless you can test.
- Vita3K's compatibility DB and issues live in `Vita3K/compatibility`. Issue 155 is P4G, 1328 is
  Madden, 177 is Gravity Rush.
