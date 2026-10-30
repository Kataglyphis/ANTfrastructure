# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# A macro, not a function: CPack reads CPACK_* from the scope that runs include(CPack), which the caller does afterwards.

include_guard(GLOBAL)

# See cmake/README.md for the CPack API; product upgrade GUIDs must be unique.

# WiX requires RTF, so encode the actual UTF-8 licence rather than displaying a placeholder.
function(kataglyphis_write_license_rtf source destination)
  file(READ "${source}" _text)
  string(STRIP "${_text}" _nonempty)
  string(LENGTH "${_nonempty}" _nonempty_length)
  if(_nonempty_length EQUAL 0)
    message(FATAL_ERROR "The project license is empty: ${source}")
  endif()
  string(
    REPLACE "\r\n"
            "\n"
            _text
            "${_text}")
  string(
    REPLACE "\r"
            "\n"
            _text
            "${_text}")
  string(HEX "${_text}" _bytes)
  string(LENGTH "${_bytes}" _length)
  set(_rtf "{\\rtf1\\ansi\\uc1\\deff0{\\fonttbl{\\f0 Arial;}}\\fs20 ")
  set(_offset 0)
  while(_offset LESS _length)
    string(
      SUBSTRING "${_bytes}"
                ${_offset}
                2
                _hex)
    math(EXPR _code "0x${_hex}")
    math(EXPR _offset "${_offset} + 2")
    if(_code GREATER_EQUAL 194 AND _code LESS_EQUAL 244)
      if(_code LESS 224)
        set(_remaining 1)
        math(EXPR _code "${_code} & 31")
        set(_minimum 128)
      elseif(_code LESS 240)
        set(_remaining 2)
        math(EXPR _code "${_code} & 15")
        set(_minimum 2048)
      else()
        set(_remaining 3)
        math(EXPR _code "${_code} & 7")
        set(_minimum 65536)
      endif()
      foreach(_unused RANGE 1 ${_remaining})
        if(_offset GREATER_EQUAL _length)
          message(FATAL_ERROR "Invalid UTF-8 in project license: ${source}")
        endif()
        string(
          SUBSTRING "${_bytes}"
                    ${_offset}
                    2
                    _hex)
        math(EXPR _continuation "0x${_hex}")
        if(_continuation LESS 128 OR _continuation GREATER 191)
          message(FATAL_ERROR "Invalid UTF-8 in project license: ${source}")
        endif()
        math(EXPR _code "(${_code} << 6) | (${_continuation} & 63)")
        math(EXPR _offset "${_offset} + 2")
      endforeach()
      if(_code LESS _minimum
         OR _code GREATER 1114111
         OR (_code GREATER_EQUAL 55296 AND _code LESS_EQUAL 57343))
        message(FATAL_ERROR "Invalid UTF-8 in project license: ${source}")
      endif()
    elseif(_code GREATER 127 OR _code EQUAL 0)
      message(FATAL_ERROR "Invalid UTF-8 in project license: ${source}")
    endif()
    if(_code EQUAL 10)
      string(APPEND _rtf "\\par\n")
    elseif(_code EQUAL 9)
      string(APPEND _rtf "\\tab ")
    elseif(_code LESS 32)
      message(FATAL_ERROR "Invalid control byte in project license: ${source}")
    elseif(_code LESS 128)
      string(ASCII ${_code} _char)
      if(_char STREQUAL "\\"
         OR _char STREQUAL "{"
         OR _char STREQUAL "}")
        string(APPEND _rtf "\\")
      endif()
      string(APPEND _rtf "${_char}")
    else()
      if(_code GREATER 65535)
        math(EXPR _code "${_code} - 65536")
        math(EXPR _high "55296 + (${_code} >> 10) - 65536")
        string(APPEND _rtf "\\u${_high}?")
        math(EXPR _code "56320 + (${_code} & 1023)")
      endif()
      if(_code GREATER 32767)
        math(EXPR _code "${_code} - 65536")
      endif()
      string(APPEND _rtf "\\u${_code}?")
    endif()
  endwhile()
  file(WRITE "${destination}" "${_rtf}}")
endfunction()

# Embedding the project ICO gives the executable its own icon in Explorer and taskbars.
function(kataglyphis_add_windows_icon target icon)
  if(NOT WIN32)
    return()
  endif()
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "kataglyphis_add_windows_icon: target does not exist: ${target}")
  endif()
  get_target_property(_type "${target}" TYPE)
  if(NOT
     _type
     STREQUAL
     "EXECUTABLE")
    message(FATAL_ERROR "kataglyphis_add_windows_icon: ${target} is not an executable")
  endif()
  if(NOT EXISTS "${icon}" OR IS_DIRECTORY "${icon}")
    message(FATAL_ERROR "kataglyphis_add_windows_icon: icon does not exist: ${icon}")
  endif()
  file(
    READ "${icon}" _header
    LIMIT 6
    HEX)
  string(LENGTH "${_header}" _header_length)
  if(NOT
     _header_length
     EQUAL
     12)
    message(FATAL_ERROR "kataglyphis_add_windows_icon: invalid ICO: ${icon}")
  endif()
  string(
    SUBSTRING "${_header}"
              0
              8
              _magic)
  string(
    SUBSTRING "${_header}"
              8
              4
              _count)
  if(NOT
     _magic
     STREQUAL
     "00000100"
     OR _count STREQUAL "0000")
    message(FATAL_ERROR "kataglyphis_add_windows_icon: invalid ICO: ${icon}")
  endif()
  get_target_property(_prior "${target}" KATAGLYPHIS_WINDOWS_ICON)
  if(_prior)
    message(FATAL_ERROR "kataglyphis_add_windows_icon: ${target} already has a project icon")
  endif()
  get_filename_component(_icon "${icon}" ABSOLUTE)
  file(TO_CMAKE_PATH "${_icon}" _icon)
  if(_icon MATCHES "[\"\r\n]")
    message(FATAL_ERROR "kataglyphis_add_windows_icon: icon path cannot contain quotes or newlines")
  endif()
  set(_resource "${CMAKE_CURRENT_BINARY_DIR}/${target}-icon.rc")
  set(_resource_text "1 ICON \"${_icon}\"\n")
  set(_existing_text "")
  if(EXISTS "${_resource}")
    file(READ "${_resource}" _existing_text)
  endif()
  if(NOT
     _existing_text
     STREQUAL
     _resource_text)
    file(WRITE "${_resource}" "${_resource_text}")
  endif()
  set_source_files_properties("${_resource}" PROPERTIES OBJECT_DEPENDS "${_icon}")
  target_sources("${target}" PRIVATE "${_resource}")
  set_property(TARGET "${target}" PROPERTY KATAGLYPHIS_WINDOWS_ICON "${_icon}")
endfunction()

# Drops vcruntime<ver>_1.dll: the arm64 redist ships it as ARM64EC, which the cross lanes' arch gate refuses.
function(kataglyphis_arm64_system_runtime_libs out_var)
  set(_libs ${ARGN})
  list(
    FILTER
    _libs
    EXCLUDE
    REGEX
    "[/\\\\]vcruntime[0-9]+_1\\.dll$")
  set(${out_var}
      "${_libs}"
      PARENT_SCOPE)
endfunction()

# Installs the DLL closure a build script staged beside the executables, so every package runs on a clean machine.
function(kataglyphis_install_package_dlls)
  set(KATAGLYPHIS_PACKAGE_DLL_DIR
      ""
      CACHE PATH "Runtime DLLs a build script staged for the packages; empty for none")
  if(KATAGLYPHIS_PACKAGE_DLL_DIR)
    install(
      DIRECTORY "${KATAGLYPHIS_PACKAGE_DLL_DIR}/"
      DESTINATION bin
      FILES_MATCHING
      PATTERN "*.dll")
  endif()
endfunction()

# Captured here: inside a function CMAKE_CURRENT_LIST_DIR is the caller's directory.
set(_KATAGLYPHIS_ELF_CLOSURE "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/06-packaging/python-app-closure.sh")
set(_KATAGLYPHIS_BUNDLE_LOADER "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/06-packaging/bundle-loader.sh")
set(_KATAGLYPHIS_PATCHELF_KEEP_GLIBC "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/06-packaging/patchelf-keep-glibc.sh")

# The Linux twin of kataglyphis_install_package_dlls; arguments: docs/linux-build-basics.md#linux-packages-that-run-outside-the-image
function(kataglyphis_install_linux_closure)
  # Embedded (AccelerANTgine in OmniAccelerANT's plugin), it would rewrite the parent's install tree, ORT included.
  if(NOT
     CMAKE_SYSTEM_NAME
     STREQUAL
     "Linux"
     OR NOT PROJECT_IS_TOP_LEVEL)
    return()
  endif()
  cmake_parse_arguments(
    ARG
    "LOADER;EXTERNAL_LIBRARY_PATH;NO_DEFAULT_SYSTEM;PRESERVE_ORT_IN_APPIMAGE"
    "PRIVATE_DIR"
    "TARGETS;SEARCH;SYSTEM;PROTECT"
    ${ARGN})
  if(NOT ARG_PRIVATE_DIR OR NOT ARG_TARGETS)
    message(FATAL_ERROR "kataglyphis_install_linux_closure: PRIVATE_DIR and TARGETS are required")
  endif()
  if(ARG_EXTERNAL_LIBRARY_PATH AND NOT ARG_LOADER)
    message(FATAL_ERROR "kataglyphis_install_linux_closure: EXTERNAL_LIBRARY_PATH requires LOADER")
  endif()
  if(ARG_PRESERVE_ORT_IN_APPIMAGE AND NOT ARG_EXTERNAL_LIBRARY_PATH)
    message(FATAL_ERROR "kataglyphis_install_linux_closure: PRESERVE_ORT_IN_APPIMAGE requires EXTERNAL_LIBRARY_PATH")
  endif()

  include(GNUInstallDirs)
  set(_libdir "${CMAKE_INSTALL_LIBDIR}")
  file(
    RELATIVE_PATH
    _bin_to_lib
    "/${CMAKE_INSTALL_BINDIR}"
    "/${_libdir}")
  set(_loader_args "")
  foreach(_target IN LISTS ARG_TARGETS)
    if(NOT TARGET ${_target})
      continue()
    endif()
    get_target_property(_type ${_target} TYPE)
    if(_type STREQUAL "EXECUTABLE")
      string(APPEND _loader_args " \"${CMAKE_INSTALL_BINDIR}/$<TARGET_FILE_NAME:${_target}>\"")
      set_property(
        TARGET ${_target}
        APPEND
        PROPERTY INSTALL_RPATH "$ORIGIN/${_bin_to_lib}")
    else()
      set_property(
        TARGET ${_target}
        APPEND
        PROPERTY INSTALL_RPATH "$ORIGIN")
    endif()
  endforeach()

  # The image has two libstdc++ (the distro's and GCC's); the code needs the one its compiler links.
  set(_args)
  if(ARG_NO_DEFAULT_SYSTEM)
    list(APPEND _args --no-default-system)
  endif()
  execute_process(
    COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libstdc++.so.6
    OUTPUT_VARIABLE _stdcxx
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(IS_ABSOLUTE "${_stdcxx}" AND EXISTS "${_stdcxx}")
    get_filename_component(_stdcxx_dir "${_stdcxx}" DIRECTORY)
    file(REAL_PATH "${_stdcxx_dir}" _stdcxx_dir)
    list(
      APPEND
      _args
      --search
      "${_stdcxx_dir}")
  endif()
  foreach(_dir IN LISTS ARG_SEARCH)
    list(
      APPEND
      _args
      --search
      "${_dir}")
  endforeach()
  foreach(_glob IN LISTS ARG_SYSTEM)
    list(
      APPEND
      _args
      --system
      "${_glob}")
  endforeach()
  foreach(_glob IN LISTS ARG_PROTECT)
    list(
      APPEND
      _args
      --protect
      "${_glob}")
  endforeach()
  set(_argstr "")
  foreach(_arg IN LISTS _args)
    string(APPEND _argstr " \"${_arg}\"")
  endforeach()

  # LOADER first: the closure then sees each executable where it will run, beside the loader.
  set(_loader_step "")
  if(ARG_LOADER)
    set(_external_loader_flag "")
    if(ARG_EXTERNAL_LIBRARY_PATH)
      set(_external_loader_flag "--external-library-path")
    endif()
    # The AppImage generator would patch the bundled loader, which then segfaults (measured 2026-10-17).
    if(ARG_PRESERVE_ORT_IN_APPIMAGE)
      set(_keep_ort_wrapper "${PROJECT_BINARY_DIR}/tools/patchelf-keep-glibc-and-ort.sh")
      file(MAKE_DIRECTORY "${PROJECT_BINARY_DIR}/tools")
      file(WRITE "${_keep_ort_wrapper}"
           "#!/usr/bin/env bash\nexec bash \"${_KATAGLYPHIS_PATCHELF_KEEP_GLIBC}\" --keep-ort \"$@\"\n")
      file(
        CHMOD
        "${_keep_ort_wrapper}"
        PERMISSIONS
        OWNER_READ
        OWNER_WRITE
        OWNER_EXECUTE
        GROUP_READ
        GROUP_EXECUTE
        WORLD_READ
        WORLD_EXECUTE)
      set(CPACK_APPIMAGE_PATCHELF_EXECUTABLE
          "${_keep_ort_wrapper}"
          PARENT_SCOPE)
    else()
      set(CPACK_APPIMAGE_PATCHELF_EXECUTABLE
          "${_KATAGLYPHIS_PATCHELF_KEEP_GLIBC}"
          PARENT_SCOPE)
    endif()
    # dpkg-shlibdeps reads the bundled glibc as the system's and pins libc6 (<< 2.44); DEBIAN_DEPENDS names the rest.
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS
        OFF
        PARENT_SCOPE)
    set(_loader_step
        "execute_process(COMMAND bash \"${_KATAGLYPHIS_BUNDLE_LOADER}\" ${_external_loader_flag} \"\${_kg_root}\"
  \"\${_kg_root}/${_libdir}/${ARG_PRIVATE_DIR}\"${_loader_args} COMMAND_ERROR_IS_FATAL ANY)
")
  endif()

  # Last install rule: it walks the staged tree each CPack generator is about to pack.
  install(CODE "set(_kg_root \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\")
${_loader_step}execute_process(COMMAND bash \"${_KATAGLYPHIS_ELF_CLOSURE}\" --bundle \"\${_kg_root}\"
  --lib-dir \"\${_kg_root}/${_libdir}/${ARG_PRIVATE_DIR}\"${_argstr} COMMAND_ERROR_IS_FATAL ANY)")
endfunction()

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
  # Spelled out per group: CMake regex has no bounded repetition, so `{8}` would match literally.
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
  set(_kgcpack_generate_license_rtf FALSE)
  if(NOT KGCPACK_WIX_LICENSE_RTF)
    set(KGCPACK_WIX_LICENSE_RTF "${PROJECT_BINARY_DIR}/kataglyphis-license.rtf")
    set(_kgcpack_generate_license_rtf TRUE)
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

  # Catch a missing installer resource at configure time, not at package time on another machine.
  foreach(_kgcpack_resource IN ITEMS LICENSE_FILE README_FILE WELCOME_FILE)
    if(NOT EXISTS "${KGCPACK_${_kgcpack_resource}}")
      message(FATAL_ERROR "kataglyphis_cpack_common: ${_kgcpack_resource} does not exist: "
                          "${KGCPACK_${_kgcpack_resource}}")
    endif()
  endforeach()
  unset(_kgcpack_resource)

  file(READ "${KGCPACK_LICENSE_FILE}" _kgcpack_license_text)
  string(STRIP "${_kgcpack_license_text}" _kgcpack_license_text)
  string(LENGTH "${_kgcpack_license_text}" _kgcpack_license_length)
  if(_kgcpack_license_length EQUAL 0)
    message(FATAL_ERROR "kataglyphis_cpack_common: LICENSE_FILE is empty: ${KGCPACK_LICENSE_FILE}")
  endif()
  unset(_kgcpack_license_text)
  unset(_kgcpack_license_length)

  install(
    FILES "${KGCPACK_LICENSE_FILE}"
    DESTINATION "share/licenses/${PROJECT_NAME}"
    RENAME LICENSE)

  # PROJECT_ARCH lets a cross build name its target, not its host.
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

  # Windows arm64 reinstalls the VC++ runtime without the ARM64EC file, at the module's own destination.
  if(WIN32
     AND KATAGLYPHIS_CPACK_ARCH STREQUAL "aarch64"
     AND NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP)
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
    include(InstallRequiredSystemLibraries)
    unset(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP)
    kataglyphis_arm64_system_runtime_libs(_kgcpack_runtime_libs ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS})
    if(NOT CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION)
      set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION bin)
    endif()
    set(_kgcpack_runtime_component)
    if(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT)
      set(_kgcpack_runtime_component COMPONENT ${CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT})
    endif()
    if(_kgcpack_runtime_libs)
      install(
        PROGRAMS ${_kgcpack_runtime_libs}
        DESTINATION ${CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION}
        ${_kgcpack_runtime_component})
    endif()
    unset(_kgcpack_runtime_libs)
    unset(_kgcpack_runtime_component)
  else()
    include(InstallRequiredSystemLibraries)
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
  # Assigned once at the end, so the AppImage icon name and the installer bitmap cannot fight over order.
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
    kataglyphis_install_package_dlls()
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

    # SetOutPath gives the shortcut bin/ as working dir; keep the four backslashes (NSIS bug, https://gitlab.kitware.com/cmake/community/-/wikis/doc/cpack/Packaging-With-CPack).
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
      # Left unset, CPack derives x64 from the pointer size and stamps an arm64 payload x64.
      if(KATAGLYPHIS_CPACK_ARCH STREQUAL "aarch64")
        set(CPACK_WIX_ARCHITECTURE "arm64")
      endif()

      if(_kgcpack_generate_license_rtf)
        set_property(
          DIRECTORY
          APPEND
          PROPERTY CMAKE_CONFIGURE_DEPENDS "${KGCPACK_LICENSE_FILE}")
        kataglyphis_write_license_rtf("${KGCPACK_LICENSE_FILE}" "${KGCPACK_WIX_LICENSE_RTF}")
      elseif(NOT EXISTS "${KGCPACK_WIX_LICENSE_RTF}")
        message(FATAL_ERROR "kataglyphis_cpack_common: WIX_LICENSE_RTF does not exist: ${KGCPACK_WIX_LICENSE_RTF}")
      endif()
      set(CPACK_WIX_LICENSE_RTF "${KGCPACK_WIX_LICENSE_RTF}")
    endif()

  else()
    # UNIX: TGZ, plus DEB and optionally an AppImage on Debian/Ubuntu.
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

        # A verified, pinned appimagetool or a failed configure; never restore a warn-and-skip path.
        include(KataglyphisAppImage)

        # An AppImage must read itself, and the image's copy is execute-only for non-root: skip it for the pinned download.
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

        # ARCH because appimagetool will not guess it; APPIMAGE_EXTRACT_AND_RUN because CI containers have no FUSE.
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
        # appimagetool 1.9 never reads the runtime the image stages; unnamed, it fetches the moving continuous one.
        foreach(_kgcpack_runtime "$ENV{HOME}/.local/share/appimagekit/runtime-${CMAKE_HOST_SYSTEM_PROCESSOR}"
                                 "/etc/skel/.local/share/appimagekit/runtime-${CMAKE_HOST_SYSTEM_PROCESSOR}")
          if(NOT CPACK_APPIMAGE_RUNTIME_FILE AND EXISTS "${_kgcpack_runtime}")
            set(CPACK_APPIMAGE_RUNTIME_FILE "${_kgcpack_runtime}")
          endif()
        endforeach()
        unset(_kgcpack_runtime)
        set(CPACK_APPIMAGE_DESKTOP_FILE "${KGCPACK_APPIMAGE_DESKTOP_FILE}")
        if(KGCPACK_APPIMAGE_ICON_NAME)
          # A name, resolved against the icons installed under share/icons.
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

  # A macro expands in the caller's scope, so clear every temporary.
  unset(_kgcpack_package_icon)
  unset(_kgcpack_arch_lc)
  unset(_kgcpack_generate_license_rtf)
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
