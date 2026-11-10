# Vita3KiOS roadmap

Vita3KiOS is upstream [Vita3K](https://github.com/Vita3K/Vita3K) with an iOS layer added on top.

## Ground rules (why this attempt is different)

1. **Stay a fork, not a copy.** `main` carries upstream history. Upstream is merged in regularly (`git fetch upstream && git merge upstream/master`), so we get their fixes for free.
2. **Keep the diff small and in one place.** iOS code lives in `vita3k/ios/`, `.ci/build-ios.sh` and `.github/workflows/ios.yml`. Changes to shared files are small `if(IOS)` / `TARGET_OS_IPHONE` guards, never rewrites. That keeps upstream merges painless and makes the changes upstreamable later.
3. **Mirror Android, not desktop.** Upstream's Android port already splits things the right way: a native UI (Kotlin), a thin C++ bridge (`vita3k/android/jni/`), and the shared SDL runner (`sdl_frontend::run`). iOS does the same with SwiftUI, an Objective-C++ bridge, and the same runner. The desktop Qt GUI isn't built on iOS.
4. **CI is the build machine.** Every push builds an IPA on GitHub Actions (plain `xcodebuild`). No Mac needed.
5. **Small, testable steps.** Each phase ends with something you can install and check.

## Platform choices

| Area | Choice |
|---|---|
| Minimum iOS | 17.4 (oldest iOS StikDebug supports) |
| Graphics | Vulkan via MoltenVK, statically linked (`moltenvk_static`) |
| Windowing/input/audio | SDL3 (static), cubeb |
| Third-party libs | vcpkg `arm64-ios` (OpenSSL, curl, zlib, boost) |
| ffmpeg | Vita3K's `ffmpeg-core` prebuilts (they already ship `ffmpeg-ios`) |
| JIT | dynarmic arm64 backend. JIT is enabled with StikDebug (needs `get-task-allow`) |
| Install | Unsigned IPA from CI → AltStore / SideStore / LiveContainer / TrollStore |

## Status

**Done**
- Full upstream Vita3K core compiles and links for iOS (arm64). Only the desktop Qt GUI is left out.
- Build: CMake generates a normal Xcode project, `xcodebuild` builds it unsigned, and CI zips it into an IPA.
- SwiftUI frontend: library grid with icons, search, JIT/firmware/font status, settings.
- Importing: firmware `.PUP`, `.vpk`, `.zip`, `.pkg` (zRIF prompt or a `.zrif` file next to it), dumped game folders, and folders holding any of those. Use the import button, or drop files into `Import/` in the Files app.
- iOS JIT taken from Tsubomi by 125hz: on iOS 26 each dynarmic code cache is a StikDebug-prepared RX mapping with a writable alias, prepared as a pool at launch; classic debugger JIT on older iOS. Guest memory is reserved before the pool so it can't be fragmented.
- Audio session and high-density full-screen game window (also from Tsubomi).
- LiveContainer-friendly: only sandbox paths through `NSFileManager`/`NSBundle`, no app extensions, no app groups or keychain, no reliance on the bundle ID.

**Next**
1. **On-device bring-up:** boot a homebrew title and fix runtime issues (MoltenVK feature gaps, file paths).
2. **Confirm JIT on device** (iOS 26 TXM through LiveContainer + universal.js) and tune the pool size.
3. **In-game controls:** touch overlay (port Android's `input_overlay`), MFi/DualSense controllers, iOS keyboard for the IME, pause menu.
4. **Polish:** background/foreground pause, audio session, ProMotion pacing, AltStore/SideStore source.

## Developer notes

- **Test builds:** Actions tab → iOS workflow → download the `Vita3K-iOS-<sha>` artifact.
- **Getting files onto the device:** the + button in the app (files or a folder), or Files app → On My iPhone → Vita3K → `Import/` (installed on next launch). A `.zrif` text file next to a `.pkg` with the same name is picked up automatically.
- **LiveContainer:** add the IPA in LiveContainer and use "Launch with JIT".
- **Logs:** `Documents/vita3k.log`.
- **Syncing upstream:** `git remote add upstream https://github.com/Vita3K/Vita3K && git fetch upstream && git merge upstream/master`
