# Vita3KiOS: app bundle settings and resources. Included from vita3k/CMakeLists.txt when IOS is set.
#
# iOS bundles are flat: the executable, Info.plist and resources all live at the root of Vita3K.app.
# Signing is not done here; CI fake-signs with ldid using ios/Vita3K.entitlements, and the sideloading
# tool (AltStore, SideStore, ...) re-signs with the user's certificate.

set(VITA3K_IOS_BUNDLE_ID "org.vita3k.ios" CACHE STRING "Bundle identifier of the iOS app")
set(VITA3K_IOS_VERSION "1.0.0" CACHE STRING "Marketing version of the iOS app")

set_target_properties(vita3k PROPERTIES
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}"
	MACOSX_BUNDLE_BUNDLE_NAME "Vita3K"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${VITA3K_IOS_VERSION}"
	MACOSX_BUNDLE_BUNDLE_VERSION "${VITA3K_IOS_VERSION}"
	XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/Vita3K.entitlements"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

add_custom_command(
	TARGET vita3k
	POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/../data" "$<TARGET_FILE_DIR:vita3k>/data"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/shaders-builtin" "$<TARGET_FILE_DIR:vita3k>/shaders-builtin"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/icons" "$<TARGET_FILE_DIR:vita3k>/icons"
	COMMENT "Copying Vita3K resources into the iOS app bundle")

# RAM helpers: V3KRamHelper.appex, an app extension that runs as separate processes (each with its own
# memory limit) and lends memory to Vita3K. Embedded in Vita3K.app/PlugIns. See ios/ramhelper/protocol.h.
add_executable(V3KRamHelper MACOSX_BUNDLE
	ios/ramhelper/extension.mm
	ios/ramhelper/protocol.h
)
set_source_files_properties(ios/ramhelper/extension.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_link_libraries(V3KRamHelper PRIVATE "-framework Foundation")
set_target_properties(V3KRamHelper PROPERTIES
	BUNDLE_EXTENSION appex
	XCODE_PRODUCT_TYPE com.apple.product-type.app-extension
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/ramhelper/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}.RamHelper"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${VITA3K_IOS_VERSION}"
	MACOSX_BUNDLE_BUNDLE_VERSION "${VITA3K_IOS_VERSION}"
	XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}.RamHelper"
	XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "16.3"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
	XCODE_ATTRIBUTE_SKIP_INSTALL YES
	XCODE_ATTRIBUTE_APPLICATION_EXTENSION_API_ONLY YES
)
add_dependencies(vita3k V3KRamHelper)
set_target_properties(vita3k PROPERTIES
	XCODE_EMBED_APP_EXTENSIONS V3KRamHelper
	XCODE_EMBED_APP_EXTENSIONS_REMOVE_HEADERS_ON_COPY YES
)
