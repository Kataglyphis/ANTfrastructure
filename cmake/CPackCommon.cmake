# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The CPack wiring that BeschleunigerBallett and AccelerANTgine each carried a
# private copy of. The two files shared 189 lines of code with no shared
# ancestry - one was seeded by copying the other - so every packaging fix had to
# be made twice and, in practice, was not: the copies had already drifted on the
# Windows package file name, on CPACK_PACKAGING_INSTALL_PREFIX, and on where
# CPACK_PACKAGE_EXECUTABLES was set.
#
# WHAT IS HERE AND WHAT IS NOT. This module owns the *mechanism*: which
# generators a platform gets, how the architecture string is normalised into the
# package name, the shape of the NSIS/WiX/DEB/AppImage blocks. It owns none of
# the *values* - icons, installer copy, the WiX upgrade GUID, the Debian
# dependency list. Those are per-product and are arguments, two of them
# mandatory precisely so a second consumer cannot inherit the first one's
# identity by accident. cmake/README.md's "packaging metadata stays in the
# consumer" rule is about exactly those values, and it still holds: the caller
# supplies every one of them.
#
# WHY A MACRO AND NOT A FUNCTION. CPack reads CPACK_* out of the directory scope
# that runs include(CPack). Variables set inside a function() would be discarded
# before CPack ever saw them, so this has to expand in the caller's scope.
#
# The caller runs include(CPack) itself, after this returns, so it can still
# override or add to anything set here.

include_guard(GLOBAL)

# Configures the CPack variables shared by the Kataglyphis C++ projects.
#
#   kataglyphis_cpack_common(
#     VENDOR                 <string>          # required: vendor + DEB maintainer
#     WIX_UPGRADE_GUID       <guid>            # required, see below
#     [EXECUTABLE            <name>]           # default ${PROJECT_NAME}
#     [LICENSE_FILE          <path>]           # default ${PROJECT_SOURCE_DIR}/LICENSE
#     [README_FILE           <path>]           # default ${PROJECT_SOURCE_DIR}/README.md
#     [WELCOME_FILE          <path>]           # default ${PROJECT_SOURCE_DIR}/docs/packaging/WelcomeFile.txt
#     [PACKAGE_ICON          <path>]           # installer icon; left unset if omitted
#     [NSIS_WELCOME_TITLE    <string>]
#     [NSIS_FINISH_TITLE     <string>]
#     [NSIS_HEADER_IMAGE     <path.bmp>]
#     [NSIS_MUI_ICON         <path.ico>]
#     [WIX_PRODUCT_ICON      <path.ico>]
#     [WIX_LICENSE_RTF       <path.rtf>]       # default ${PROJECT_SOURCE_DIR}/LICENSE.rtf, synthesised if absent
#     [WIX_DEFAULT           ON|OFF]           # default OFF: initial ENABLE_WIX_PACKAGING
#     [APPIMAGE_DEFAULT      ON|OFF]           # default ON:  initial CPACK_ENABLE_APPIMAGE
#     [APPIMAGE_DESKTOP_FILE <name.desktop>]   # required once AppImage packaging can run
#     [APPIMAGE_ICON_NAME    <name>]           # installed icon name, NOT a path
#     [DEBIAN_DEPENDS        <string>]         # default "libc6 (>= 2.31)"
#     [DEBIAN_SECTION        <string>]         # default "devel"
#     [DEBIAN_PRIORITY       <string>]         # default "optional"
#     [UNIX_INSTALL_PREFIX   <path>]           # CPACK_PACKAGING_INSTALL_PREFIX; unset if omitted
#     [SHORT_WINDOWS_FILE_NAME])               # see below
#
# WIX_UPGRADE_GUID is mandatory and deliberately has NO default. An MSI upgrade
# code is a product's identity: two products sharing one means installing either
# silently uninstalls the other. The two consumers this module was hoisted from
# were carrying the SAME literal GUID, which is the bug that made this a
# required parameter rather than an optional one with a fallback.
#
# SHORT_WINDOWS_FILE_NAME replaces the fully descriptive package file name with
# <project>-<version>-<config>-<arch> on Windows only. The long name embeds the
# compiler id and version, which is what you want for tracking an ABI back to a
# build - but NSIS resolves paths against MAX_PATH, and a deep workspace plus
# the long name overflows it.
#
# Leaves KATAGLYPHIS_CPACK_ARCH set for the caller: the normalised architecture
# that went into the package name.
macro(kataglyphis_cpack_common)
  set(_kgcpack_flags SHORT_WINDOWS_FILE_NAME)
  set(_kgcpack_args
      VENDOR
      EXECUTABLE
      LICENSE_FILE
      README_FILE
      WELCOME_FILE
      PACKAGE_ICON
      NSIS_WELCOME_TITLE
      NSIS_FINISH_TITLE
      NSIS_HEADER_IMAGE
      NSIS_MUI_ICON
      WIX_UPGRADE_GUID
      WIX_PRODUCT_ICON
      WIX_LICENSE_RTF
      WIX_DEFAULT
      APPIMAGE_DEFAULT
      APPIMAGE_DESKTOP_FILE
      APPIMAGE_ICON_NAME
      DEBIAN_DEPENDS
      DEBIAN_SECTION
      DEBIAN_PRIORITY
      UNIX_INSTALL_PREFIX)
  cmake_parse_arguments(
    KGCPACK
    "${_kgcpack_flags}"
    "${_kgcpack_args}"
    ""
    ${ARGN})

  if(KGCPACK_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "kataglyphis_cpack_common: unexpected argument(s) '${KGCPACK_UNPARSED_ARGUMENTS}'")
  endif()
  if(KGCPACK_KEYWORDS_MISSING_VALUES)
    message(FATAL_ERROR "kataglyphis_cpack_common: keyword(s) given with no value: "
                        "'${KGCPACK_KEYWORDS_MISSING_VALUES}'")
  endif()
  if(NOT KGCPACK_VENDOR)
    message(FATAL_ERROR "kataglyphis_cpack_common: VENDOR is required - it becomes CPACK_PACKAGE_VENDOR and the "
                        "Debian maintainer field.")
  endif()
  # Shape-check rather than trust: a mistyped GUID reaches WiX as a failure in a
  # Windows-only packaging job, long after the configure that accepted it.
  #
  # Spelled out group by group because CMake's regex engine has no bounded
  # repetition - `[0-9A-Fa-f]{8}` is matched LITERALLY, so the obvious pattern
  # rejects every well-formed GUID instead of the malformed ones.
  set(_kgcpack_hex4 "[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]")
  if(NOT
     KGCPACK_WIX_UPGRADE_GUID
     MATCHES
     "^${_kgcpack_hex4}${_kgcpack_hex4}-${_kgcpack_hex4}-${_kgcpack_hex4}-${_kgcpack_hex4}-${_kgcpack_hex4}${_kgcpack_hex4}${_kgcpack_hex4}$"
  )
    message(
      FATAL_ERROR
        "kataglyphis_cpack_common: WIX_UPGRADE_GUID must be a GUID like '01234567-89AB-CDEF-0123-456789ABCDEF'; "
        "got '${KGCPACK_WIX_UPGRADE_GUID}'. It has no default on purpose: the upgrade code is this product's "
        "identity, and two products sharing one uninstall each other. Generate it once, then never change it.")
  endif()
  unset(_kgcpack_hex4)

  if(NOT KGCPACK_EXECUTABLE)
    set(KGCPACK_EXECUTABLE "${PROJECT_NAME}")
  endif()
  if(NOT KGCPACK_LICENSE_FILE)
    set(KGCPACK_LICENSE_FILE "${PROJECT_SOURCE_DIR}/LICENSE")
  endif()
  if(NOT KGCPACK_README_FILE)
    set(KGCPACK_README_FILE "${PROJECT_SOURCE_DIR}/README.md")
  endif()
  if(NOT KGCPACK_WELCOME_FILE)
    set(KGCPACK_WELCOME_FILE "${PROJECT_SOURCE_DIR}/docs/packaging/WelcomeFile.txt")
  endif()
  if(NOT KGCPACK_WIX_LICENSE_RTF)
    set(KGCPACK_WIX_LICENSE_RTF "${PROJECT_SOURCE_DIR}/LICENSE.rtf")
  endif()
  if(NOT DEFINED KGCPACK_WIX_DEFAULT)
    set(KGCPACK_WIX_DEFAULT OFF)
  endif()
  if(NOT DEFINED KGCPACK_APPIMAGE_DEFAULT)
    set(KGCPACK_APPIMAGE_DEFAULT ON)
  endif()
  if(NOT KGCPACK_DEBIAN_DEPENDS)
    set(KGCPACK_DEBIAN_DEPENDS "libc6 (>= 2.31)")
  endif()
  if(NOT KGCPACK_DEBIAN_SECTION)
    set(KGCPACK_DEBIAN_SECTION "devel")
  endif()
  if(NOT KGCPACK_DEBIAN_PRIORITY)
    set(KGCPACK_DEBIAN_PRIORITY "optional")
  endif()

  # The resource files are shown in the installer UI. A missing one surfaces as
  # an empty licence page, or as a CPack failure at package time on a machine
  # that is not the one that made the mistake. Catch it at configure time.
  foreach(_kgcpack_resource IN ITEMS LICENSE_FILE README_FILE WELCOME_FILE)
    if(NOT EXISTS "${KGCPACK_${_kgcpack_resource}}")
      message(FATAL_ERROR "kataglyphis_cpack_common: ${_kgcpack_resource} does not exist: "
                          "${KGCPACK_${_kgcpack_resource}}")
    endif()
  endforeach()
  unset(_kgcpack_resource)

  include(InstallRequiredSystemLibraries)

  # Explicit package naming makes an ABI problem visible in the file name before
  # anyone unpacks it, and ties a build to one toolchain. PROJECT_ARCH is
  # honoured as an override so a cross build can name its target, not its host.
  if(NOT DEFINED PROJECT_ARCH)
    if(CMAKE_SYSTEM_PROCESSOR)
      set(PROJECT_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
    else()
      execute_process(
        COMMAND uname -m
        OUTPUT_VARIABLE PROJECT_ARCH
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    endif()
  endif()
  string(TOLOWER "${PROJECT_ARCH}" _kgcpack_arch_lc)
  set(KATAGLYPHIS_CPACK_ARCH "${_kgcpack_arch_lc}")
  if(_kgcpack_arch_lc STREQUAL "x86_64" OR _kgcpack_arch_lc STREQUAL "amd64")
    set(KATAGLYPHIS_CPACK_ARCH "x86_64")
  elseif(_kgcpack_arch_lc STREQUAL "aarch64" OR _kgcpack_arch_lc STREQUAL "arm64")
    set(KATAGLYPHIS_CPACK_ARCH "aarch64")
  endif()

  set(CPACK_PACKAGE_NAME "${PROJECT_NAME}")
  set(CPACK_PACKAGE_FILE_NAME
      "${PROJECT_NAME}-${PROJECT_VERSION}-${CMAKE_SYSTEM_NAME}-${KATAGLYPHIS_CPACK_ARCH}-${CMAKE_BUILD_TYPE}-${CMAKE_CXX_COMPILER_ID}-${CMAKE_CXX_COMPILER_VERSION}"
  )
  set(CPACK_PACKAGE_VENDOR "${KGCPACK_VENDOR}")
  set(CPACK_RESOURCE_FILE_LICENSE "${KGCPACK_LICENSE_FILE}")
  set(CPACK_RESOURCE_FILE_README "${KGCPACK_README_FILE}")
  set(CPACK_RESOURCE_FILE_WELCOME "${KGCPACK_WELCOME_FILE}")
  set(CPACK_PACKAGE_VERSION_MAJOR "${PROJECT_VERSION_MAJOR}")
  set(CPACK_PACKAGE_VERSION_MINOR "${PROJECT_VERSION_MINOR}")
  set(CPACK_PACKAGE_DESCRIPTION "${PROJECT_DESCRIPTION}")
  set(CPACK_PACKAGE_HOMEPAGE_URL "${PROJECT_HOMEPAGE_URL}")
  set(CPACK_PACKAGE_EXECUTABLES "${KGCPACK_EXECUTABLE}" "${KGCPACK_EXECUTABLE}")
  # Assigned to CPACK_PACKAGE_ICON once, at the very end: the AppImage branch
  # replaces the installer bitmap with an installed icon NAME, and routing both
  # through one variable is what stops them fighting over statement order.
  set(_kgcpack_package_icon "${KGCPACK_PACKAGE_ICON}")
  # Use all cores.
  set(CPACK_THREADS 0)
  set(CPACK_SOURCE_IGNORE_FILES /.git /.*build.*)

  set(CPACK_ENABLE_APPIMAGE
      ${KGCPACK_APPIMAGE_DEFAULT}
      CACHE BOOL "Enable AppImage package generation on Linux")
  set(ENABLE_WIX_PACKAGING
      ${KGCPACK_WIX_DEFAULT}
      CACHE BOOL "Enable WiX MSI package generation on Windows")

  if(WIN32)
    if(KGCPACK_SHORT_WINDOWS_FILE_NAME)
      set(CPACK_PACKAGE_FILE_NAME "${PROJECT_NAME}-${PROJECT_VERSION}-${CMAKE_BUILD_TYPE}-${KATAGLYPHIS_CPACK_ARCH}")
    endif()

    set(CPACK_GENERATOR "NSIS;ZIP")
    if(ENABLE_WIX_PACKAGING)
      set(CPACK_GENERATOR "${CPACK_GENERATOR};WIX")
    endif()
    set(CPACK_SOURCE_GENERATOR "ZIP")

    set(CPACK_NSIS_WELCOME_TITLE "${KGCPACK_NSIS_WELCOME_TITLE}")
    set(CPACK_NSIS_FINISH_TITLE "${KGCPACK_NSIS_FINISH_TITLE}")
    set(CPACK_NSIS_MUI_HEADERIMAGE "${KGCPACK_NSIS_HEADER_IMAGE}")
    set(CPACK_NSIS_MUI_WELCOMEFINISHPAGE_BITMAP "${KGCPACK_NSIS_HEADER_IMAGE}")
    set(CPACK_NSIS_MUI_UNWELCOMEFINISHPAGE_BITMAP "${KGCPACK_NSIS_HEADER_IMAGE}")
    set(CPACK_NSIS_MUI_ICON "${KGCPACK_NSIS_MUI_ICON}")
    set(CPACK_NSIS_INSTALLED_ICON_NAME "bin/${KGCPACK_EXECUTABLE}.exe")
    set(CPACK_NSIS_PACKAGE_NAME "${PROJECT_NAME}")
    set(CPACK_NSIS_DISPLAY_NAME "${PROJECT_NAME}")
    set(CPACK_NSIS_CONTACT "${PROJECT_HOMEPAGE_URL}")
    set(CPACK_NSIS_URL_INFO_ABOUT "${PROJECT_HOMEPAGE_URL}")
    set(CPACK_NSIS_HELP_LINK "${PROJECT_HOMEPAGE_URL}")
    set(CPACK_NSIS_MENU_LINKS "${PROJECT_HOMEPAGE_URL}" "Homepage for ${PROJECT_NAME}")
    set(CPACK_NSIS_ENABLE_UNINSTALL_BEFORE_INSTALL ON)
    set(CPACK_NSIS_MODIFY_PATH "ON")
    set(CPACK_PACKAGE_INSTALL_REGISTRY_KEY "${PROJECT_NAME}-${PROJECT_VERSION}")
    set(CPACK_CREATE_DESKTOP_LINKS "${KGCPACK_EXECUTABLE}")
    # Standard install location, under Program Files.
    set(CPACK_PACKAGE_INSTALL_DIRECTORY "${PROJECT_NAME}")

    # CPACK_CREATE_DESKTOP_LINKS on its own makes a shortcut whose working
    # directory is the install root, so the exe cannot find what it loads
    # relative to itself. SetOutPath before CreateShortCut is what fixes that.
    #
    # There is a bug in NSIS that does not handle full UNIX paths properly, so
    # keep at least one set of four backslashes:
    # https://gitlab.kitware.com/cmake/community/-/wikis/doc/cpack/Packaging-With-CPack
    set(CPACK_NSIS_EXTRA_INSTALL_COMMANDS
        "
    SetOutPath \\\"$INSTDIR\\\\bin\\\"
    CreateShortCut \\\"$DESKTOP\\\\${KGCPACK_EXECUTABLE}.lnk\\\" \\\"$INSTDIR\\\\bin\\\\${KGCPACK_EXECUTABLE}.exe\\\" \\\"\\\" \\\"$INSTDIR\\\\bin\\\\${KGCPACK_EXECUTABLE}.exe\\\" 0 SW_SHOWNORMAL \\\"\\\" \\\"${PROJECT_NAME}\\\"
  ")
    set(CPACK_NSIS_EXTRA_UNINSTALL_COMMANDS
        "
    Delete \\\"$DESKTOP\\\\${KGCPACK_EXECUTABLE}.lnk\\\"
  ")

    if(ENABLE_WIX_PACKAGING)
      set(CPACK_WIX_VERSION 4)
      set(CPACK_WIX_UPGRADE_GUID "${KGCPACK_WIX_UPGRADE_GUID}")
      set(CPACK_WIX_PRODUCT_ICON "${KGCPACK_WIX_PRODUCT_ICON}")
      set(CPACK_WIX_PROGRAM_MENU_FOLDER "${PROJECT_NAME}")
      set(CPACK_WIX_USE_LONG_FILE_NAMES ON)
      set(CPACK_WIX_PROPERTY_ARPURLINFOABOUT "${PROJECT_HOMEPAGE_URL}")
      set(CPACK_WIX_PROPERTY_ARPHELPLINK "${PROJECT_HOMEPAGE_URL}")

      # WiX accepts only real RTF for the licence page and aborts with
      # 'unsupported WiX License file extension' otherwise. Both consumers keep
      # a checked-in LICENSE.rtf, so this synthesis is the fallback for a fresh
      # tree that has not got one yet - not something that runs on every
      # configure.
      if(NOT EXISTS "${KGCPACK_WIX_LICENSE_RTF}")
        file(
          WRITE "${KGCPACK_WIX_LICENSE_RTF}"
          "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}\\fs20 This software is licensed under the terms described in the accompanying LICENSE file.\\par}"
        )
      endif()
      set(CPACK_WIX_LICENSE_RTF "${KGCPACK_WIX_LICENSE_RTF}")
    endif()

  else()
    # Linux and other UNIX systems. Source stays TGZ; binaries are TGZ plus, on
    # Debian/Ubuntu, DEB and optionally an AppImage.
    if(KGCPACK_UNIX_INSTALL_PREFIX)
      set(CPACK_PACKAGING_INSTALL_PREFIX "${KGCPACK_UNIX_INSTALL_PREFIX}")
    endif()
    set(CPACK_SOURCE_GENERATOR "TGZ")

    if(UNIX AND NOT APPLE)
      set(CPACK_GENERATOR "TGZ;DEB")
      set(CPACK_DEBIAN_PACKAGE_MAINTAINER "${KGCPACK_VENDOR}")
      set(CPACK_DEBIAN_PACKAGE_SECTION "${KGCPACK_DEBIAN_SECTION}")
      set(CPACK_DEBIAN_PACKAGE_PRIORITY "${KGCPACK_DEBIAN_PRIORITY}")
      set(CPACK_DEBIAN_PACKAGE_DEPENDS "${KGCPACK_DEBIAN_DEPENDS}")
      set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
      # Debian has its own architecture names; dpkg rejects 'x86_64'.
      if(NOT DEFINED CPACK_DEBIAN_PACKAGE_ARCHITECTURE)
        if(KATAGLYPHIS_CPACK_ARCH STREQUAL "x86_64")
          set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "amd64")
        elseif(KATAGLYPHIS_CPACK_ARCH STREQUAL "aarch64")
          set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "arm64")
        else()
          set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "${KATAGLYPHIS_CPACK_ARCH}")
        endif()
      endif()

      if(CPACK_ENABLE_APPIMAGE)
        if(NOT KGCPACK_APPIMAGE_DESKTOP_FILE)
          message(
            FATAL_ERROR
              "kataglyphis_cpack_common: CPACK_ENABLE_APPIMAGE is ON but APPIMAGE_DESKTOP_FILE was not given. The "
              "AppImage generator needs the name of the .desktop file this project installs into "
              "share/applications; without it CPack produces an AppImage no desktop can launch.")
        endif()

        # appimagetool comes from KataglyphisAppImage, which provisions it from
        # an IMMUTABLE release tag against the SHA256 pinned in
        # linux/scripts/01-core/versions.env and calls message(FATAL_ERROR) when
        # either the download or the checksum does not hold.
        #
        # WHAT THIS REPLACES, and why the replacement is not like-for-like: the
        # blocks that stood in both consumers downloaded appimagetool from the
        # MUTABLE `continuous` tag with no EXPECTED_HASH, and reported both a
        # failed download and "no appimagetool available at all" with
        # message(WARNING). CPACK_ENABLE_APPIMAGE=ON therefore produced a green
        # Package job with no AppImage in it - the request was silently dropped
        # - and, when the download did succeed, packaged with bytes nobody had
        # verified.
        #
        # DELIBERATE BEHAVIOUR CHANGE: a packaging job that cannot get a
        # verified tool now FAILS the configure step instead of skipping the
        # generator. Runs that were quietly shipping only TGZ/DEB will start
        # going red; that is the point, and the fix is to make the tool
        # available, never to restore the warning.
        include(KataglyphisAppImage)

        # A type-2 AppImage must READ its own appended squashfs (through
        # /proc/self/exe) to run - even with APPIMAGE_EXTRACT_AND_RUN=1, which
        # only skips the FUSE mount. The :latest-cross image ships
        # /usr/local/bin/appimagetool as -rwx--x--x (execute-only for non-root),
        # so the CI user (uid 1001) can exec but not read it, and it dies with
        # "Cannot open /proc/self/exe: Permission denied". compare_files against
        # itself is a portable read-access probe: it opens the file for reading
        # and returns non-zero if it cannot.
        #
        # KataglyphisAppImage prefers an appimagetool on PATH (inside a
        # ANTfrastructure image that IS the checksum-verified one packaging-deps.sh
        # installed). NO_SYSTEM_SEARCH is how we tell it to skip that step when
        # the PATH copy is the unreadable one, so it downloads the pinned asset
        # - which it chmods world-readable - instead of handing back a tool that
        # cannot run.
        set(_kgcpack_provision_args "")
        find_program(KATAGLYPHIS_CPACK_APPIMAGETOOL_ON_PATH NAMES appimagetool)
        if(KATAGLYPHIS_CPACK_APPIMAGETOOL_ON_PATH)
          execute_process(
            COMMAND "${CMAKE_COMMAND}" -E compare_files "${KATAGLYPHIS_CPACK_APPIMAGETOOL_ON_PATH}"
                    "${KATAGLYPHIS_CPACK_APPIMAGETOOL_ON_PATH}"
            RESULT_VARIABLE _kgcpack_appimagetool_readable
            OUTPUT_QUIET ERROR_QUIET)
          if(NOT
             _kgcpack_appimagetool_readable
             EQUAL
             0)
            message(
              STATUS
                "appimagetool at ${KATAGLYPHIS_CPACK_APPIMAGETOOL_ON_PATH} is not readable (execute-only); ignoring it so the pinned, checksum-verified one is fetched instead."
            )
            set(_kgcpack_provision_args NO_SYSTEM_SEARCH)
          endif()
          unset(_kgcpack_appimagetool_readable)
        endif()

        kataglyphis_provision_appimagetool(_kgcpack_appimagetool ${_kgcpack_provision_args})
        unset(_kgcpack_provision_args)

        # No `if(_kgcpack_appimagetool)` guard: the call above either returns a
        # verified tool or stops the configure. A guard here would be dead code
        # pretending the skip path still exists.
        #
        # ARCH is exported because appimagetool refuses to guess it when the
        # host and the payload could disagree, and APPIMAGE_EXTRACT_AND_RUN
        # because the CI containers have no FUSE.
        set(_kgcpack_wrapper "${PROJECT_BINARY_DIR}/tools/appimagetool-wrapper.sh")
        file(MAKE_DIRECTORY "${PROJECT_BINARY_DIR}/tools")
        file(
          WRITE "${_kgcpack_wrapper}"
          "#!/usr/bin/env sh\nARCH=${KATAGLYPHIS_CPACK_ARCH} APPIMAGE_EXTRACT_AND_RUN=1 \"${_kgcpack_appimagetool}\" \"$@\"\n"
        )
        file(
          CHMOD
          "${_kgcpack_wrapper}"
          PERMISSIONS
          OWNER_READ
          OWNER_WRITE
          OWNER_EXECUTE
          GROUP_READ
          GROUP_EXECUTE
          WORLD_READ
          WORLD_EXECUTE)

        list(APPEND CPACK_GENERATOR "AppImage")
        set(CPACK_APPIMAGE_TOOL_EXECUTABLE "${_kgcpack_wrapper}")
        set(CPACK_APPIMAGE_DESKTOP_FILE "${KGCPACK_APPIMAGE_DESKTOP_FILE}")
        if(KGCPACK_APPIMAGE_ICON_NAME)
          # Not a path: the AppImage generator resolves this against the icons
          # the project installed under share/icons.
          set(_kgcpack_package_icon "${KGCPACK_APPIMAGE_ICON_NAME}")
        endif()
        message(STATUS "AppImage packaging enabled with appimagetool: ${_kgcpack_appimagetool}")
        unset(_kgcpack_wrapper)
        unset(_kgcpack_appimagetool)
      endif()
    endif()
  endif()

  if(_kgcpack_package_icon)
    set(CPACK_PACKAGE_ICON "${_kgcpack_package_icon}")
  endif()

  # A macro expands in the caller's scope, so every temporary above would
  # otherwise stay visible to the rest of the project.
  unset(_kgcpack_package_icon)
  unset(_kgcpack_arch_lc)
  unset(_kgcpack_flags)
  unset(_kgcpack_args)
  unset(KGCPACK_UNPARSED_ARGUMENTS)
  unset(KGCPACK_KEYWORDS_MISSING_VALUES)
  unset(KGCPACK_SHORT_WINDOWS_FILE_NAME)
  unset(KGCPACK_VENDOR)
  unset(KGCPACK_EXECUTABLE)
  unset(KGCPACK_LICENSE_FILE)
  unset(KGCPACK_README_FILE)
  unset(KGCPACK_WELCOME_FILE)
  unset(KGCPACK_PACKAGE_ICON)
  unset(KGCPACK_NSIS_WELCOME_TITLE)
  unset(KGCPACK_NSIS_FINISH_TITLE)
  unset(KGCPACK_NSIS_HEADER_IMAGE)
  unset(KGCPACK_NSIS_MUI_ICON)
  unset(KGCPACK_WIX_UPGRADE_GUID)
  unset(KGCPACK_WIX_PRODUCT_ICON)
  unset(KGCPACK_WIX_LICENSE_RTF)
  unset(KGCPACK_WIX_DEFAULT)
  unset(KGCPACK_APPIMAGE_DEFAULT)
  unset(KGCPACK_APPIMAGE_DESKTOP_FILE)
  unset(KGCPACK_APPIMAGE_ICON_NAME)
  unset(KGCPACK_DEBIAN_DEPENDS)
  unset(KGCPACK_DEBIAN_SECTION)
  unset(KGCPACK_DEBIAN_PRIORITY)
  unset(KGCPACK_UNIX_INSTALL_PREFIX)
endmacro()
