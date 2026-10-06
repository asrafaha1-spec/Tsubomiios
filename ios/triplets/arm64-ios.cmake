# arm64 iOS device triplet with an explicit deployment target.
#
# This overrides vcpkg's built-in arm64-ios, which is otherwise identical but
# leaves the deployment target unset, so every dependency (ffmpeg, openssl,
# curl, boost, ...) is compiled for the newest iOS in the installed SDK. The
# app itself targets iOS 16.3 (see VITA3K_IOS_DEPLOYMENT_TARGET), and linking
# libraries built for a newer OS produces "built for newer iOS version"
# warnings and can pull in code paths that do not exist on older systems.
#
# Keep VCPKG_OSX_DEPLOYMENT_TARGET equal to VITA3K_IOS_DEPLOYMENT_TARGET.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET 16.3)
