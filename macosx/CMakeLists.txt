# Native macOS (Cocoa) front end for PuTTY.
#
# Reuses PuTTY's portable cores and replaces only the GTK layer with
# AppKit. Built only on Apple platforms, and only when GTK was NOT
# selected (so the portable libraries are free of GTK contamination).

if(NOT APPLE)
  return()
endif()

enable_language(OBJC)

# PuTTY forbids NDEBUG; strip it from the ObjC release flags the same way
# setup.cmake does for the C flags.
string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_RELEASE "${CMAKE_OBJC_FLAGS_RELEASE}")
string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_RELWITHDEBINFO "${CMAKE_OBJC_FLAGS_RELWITHDEBINFO}")

include_directories(${CMAKE_CURRENT_SOURCE_DIR})

set(MAC_FRAMEWORKS
  "-framework Cocoa"
  "-framework CoreText"
  "-framework CoreGraphics"
  "-framework ImageIO"
  "-framework CoreFoundation")

# ---- main PuTTY app (terminal + SSH client; NO keygen) ----
set(COCOA_SOURCES
  cocoa-main.m
  cocoa-terminal.m
  cocoa-eventloop.m
  cocoa-dialog.m
  cocoa-glue.c
  # Unix POSIX pieces we still need but which live outside the GTK block:
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  # Terminal references the printer API; we don't print, so stub it out:
  ${CMAKE_SOURCE_DIR}/stubs/no-print.c)

set(APP_ICON ${CMAKE_CURRENT_SOURCE_DIR}/PuTTY.icns)
set_source_files_properties(${APP_ICON} PROPERTIES
  MACOSX_PACKAGE_LOCATION "Resources")

option(PUTTY_MAC_DEBUG
  "Compile in macOS debug logging (PUTTY_DEBUG) and test hooks (PUTTY_TEST_*)"
  OFF)

add_executable(PuTTY MACOSX_BUNDLE ${COCOA_SOURCES} ${APP_ICON})
be_list(PuTTY PuTTY SSH SERIAL OTHERBACKENDS)
if(PUTTY_MAC_DEBUG)
  target_compile_definitions(PuTTY PRIVATE PUTTY_MAC_DEBUG=1)
endif()
target_link_libraries(PuTTY
  guiterminal eventloop sshclient otherbackends settings
  network crypto utils ${MAC_FRAMEWORKS})

set_target_properties(PuTTY PROPERTIES
  MACOSX_BUNDLE_ICON_FILE "PuTTY.icns"
  MACOSX_BUNDLE_BUNDLE_NAME "PuTTY"
  MACOSX_BUNDLE_GUI_IDENTIFIER "org.tartarus.projects.putty.macputty"
  MACOSX_BUNDLE_BUNDLE_VERSION "0.84"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "0.84"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")

# ---- PuTTYgen helper (key generator; separate binary because its
#      variable-time bignum math must not share a process with the
#      constant-time SSH client) ----
add_executable(macputtygen
  cocoa-puttygen.m
  cocoa-gen-glue.c
  # Mirror upstream's puttygen-common object set (avoids linking the SSH
  # client libraries, which would re-introduce the deliberate clash):
  ${CMAKE_SOURCE_DIR}/sshpubk.c
  ${CMAKE_SOURCE_DIR}/sshrand.c
  ${CMAKE_SOURCE_DIR}/unix/noise.c
  ${CMAKE_SOURCE_DIR}/unix/keygen-noise.c
  ${CMAKE_SOURCE_DIR}/unix/no-gtk.c
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c)
set_target_properties(macputtygen PROPERTIES OUTPUT_NAME puttygen
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/macosx)
target_link_libraries(macputtygen
  keygen console settings crypto utils ${MAC_FRAMEWORKS})
if(PUTTY_MAC_DEBUG)
  target_compile_definitions(macputtygen PRIVATE PUTTY_MAC_DEBUG=1)
endif()

# Embed the PuTTYgen helper inside PuTTY.app/Contents/MacOS so the menu
# item can launch it.
add_dependencies(macputtygen PuTTY)
add_custom_command(TARGET macputtygen POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy
    $<TARGET_FILE:macputtygen>
    $<TARGET_BUNDLE_CONTENT_DIR:PuTTY>/MacOS/puttygen)
