# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# appimagetool from the immutable tag and SHA256 pinned in versions.env; no warn-and-continue branch, an unverified tool stops the configure.

include_guard(GLOBAL)

# Relative to this module, so it resolves both here and in a consumer's third_party/ANTfrastructure.
set(KATAGLYPHIS_VERSIONS_ENV
    "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/01-core/versions.env"
    CACHE FILEPATH "ANTfrastructure versions.env holding the appimagetool pins")

# Reads one KEY=VALUE out of a versions.env-shaped file.
function(
  _kataglyphis_read_versions_env_key
  out_var
  versions_env
  key)
  if(NOT EXISTS "${versions_env}")
    message(
      FATAL_ERROR
        "KataglyphisAppImage: pin file not found: ${versions_env}\n"
        "This module reads ANTfrastructure's linux/scripts/01-core/versions.env. If the ANTfrastructure "
        "submodule is not checked out, run: git submodule update --init --recursive. To point at a "
        "different pin file, set -DKATAGLYPHIS_VERSIONS_ENV=<path>.")
  endif()

  file(STRINGS "${versions_env}" _kataglyphis_matches REGEX "^${key}=")
  list(LENGTH _kataglyphis_matches _kataglyphis_match_count)
  if(_kataglyphis_match_count EQUAL 0)
    message(FATAL_ERROR "KataglyphisAppImage: '${key}' is not defined in ${versions_env}.")
  endif()

  # Last assignment wins, matching how a shell would source the file.
  list(
    GET
    _kataglyphis_matches
    -1
    _kataglyphis_line)
  string(
    REGEX
    REPLACE "^${key}="
            ""
            _kataglyphis_value
            "${_kataglyphis_line}")
  string(STRIP "${_kataglyphis_value}" _kataglyphis_value)
  string(
    REGEX
    REPLACE "[\"']"
            ""
            _kataglyphis_value
            "${_kataglyphis_value}")

  if("${_kataglyphis_value}" STREQUAL "")
    message(FATAL_ERROR "KataglyphisAppImage: '${key}' is empty in ${versions_env}.")
  endif()

  set(${out_var}
      "${_kataglyphis_value}"
      PARENT_SCOPE)
endfunction()

# Resolves the pinned appimagetool release for a host arch (the tool runs on the build host, not the target).
#   kataglyphis_appimagetool_pin(<out_version> <out_asset> <out_sha256> [ARCH <uname -m>] [VERSIONS_ENV <file>])
function(
  kataglyphis_appimagetool_pin
  out_version
  out_asset
  out_sha256)
  cmake_parse_arguments(
    KATAGLYPHIS_APPIMAGE
    ""
    "ARCH;VERSIONS_ENV"
    ""
    ${ARGN})
  if(KATAGLYPHIS_APPIMAGE_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "kataglyphis_appimagetool_pin: unexpected argument(s) "
                        "'${KATAGLYPHIS_APPIMAGE_UNPARSED_ARGUMENTS}'")
  endif()

  if(NOT KATAGLYPHIS_APPIMAGE_VERSIONS_ENV)
    set(KATAGLYPHIS_APPIMAGE_VERSIONS_ENV "${KATAGLYPHIS_VERSIONS_ENV}")
  endif()
  if(NOT KATAGLYPHIS_APPIMAGE_ARCH)
    set(KATAGLYPHIS_APPIMAGE_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
  endif()
  if(NOT KATAGLYPHIS_APPIMAGE_ARCH)
    # CMAKE_HOST_SYSTEM_PROCESSOR is empty in script mode (cmake -P), before any project().
    if(CMAKE_HOST_UNIX)
      execute_process(
        COMMAND uname -m
        OUTPUT_VARIABLE KATAGLYPHIS_APPIMAGE_ARCH
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    else()
      set(KATAGLYPHIS_APPIMAGE_ARCH "$ENV{PROCESSOR_ARCHITECTURE}")
    endif()
  endif()
  if(NOT KATAGLYPHIS_APPIMAGE_ARCH)
    message(FATAL_ERROR "KataglyphisAppImage: could not determine the host architecture. Pass it "
                        "explicitly: kataglyphis_appimagetool_pin(... ARCH <uname -m value>).")
  endif()

  # Mirrors packaging-deps.sh ensure_appimagetool arm for arm, so both paths pick the same asset.
  if(KATAGLYPHIS_APPIMAGE_ARCH MATCHES "^(x86_64|amd64|AMD64)$")
    set(_kataglyphis_asset_arch "x86_64")
    set(_kataglyphis_sha_key "APPIMAGETOOL_X86_64_SHA256")
  elseif(KATAGLYPHIS_APPIMAGE_ARCH MATCHES "^(aarch64|arm64|ARM64)$")
    set(_kataglyphis_asset_arch "aarch64")
    set(_kataglyphis_sha_key "APPIMAGETOOL_AARCH64_SHA256")
  elseif(KATAGLYPHIS_APPIMAGE_ARCH MATCHES "^(armv7l|armhf)$")
    set(_kataglyphis_asset_arch "armhf")
    set(_kataglyphis_sha_key "APPIMAGETOOL_ARMHF_SHA256")
  elseif(KATAGLYPHIS_APPIMAGE_ARCH MATCHES "^(i686|i386)$")
    set(_kataglyphis_asset_arch "i686")
    set(_kataglyphis_sha_key "APPIMAGETOOL_I686_SHA256")
  else()
    message(
      FATAL_ERROR
        "KataglyphisAppImage: no pinned appimagetool asset for host architecture "
        "'${KATAGLYPHIS_APPIMAGE_ARCH}'. Supported: x86_64, aarch64, armv7l, i686. "
        "AppImage packaging cannot be done on this host.")
  endif()

  _kataglyphis_read_versions_env_key(_kataglyphis_version "${KATAGLYPHIS_APPIMAGE_VERSIONS_ENV}" "APPIMAGETOOL_VERSION")
  _kataglyphis_read_versions_env_key(_kataglyphis_sha "${KATAGLYPHIS_APPIMAGE_VERSIONS_ENV}" "${_kataglyphis_sha_key}")

  set(${out_version}
      "${_kataglyphis_version}"
      PARENT_SCOPE)
  set(${out_asset}
      "appimagetool-${_kataglyphis_asset_arch}.AppImage"
      PARENT_SCOPE)
  set(${out_sha256}
      "${_kataglyphis_sha}"
      PARENT_SCOPE)
endfunction()

# Returns a verified appimagetool: -DKATAGLYPHIS_APPIMAGETOOL, else PATH (unless NO_SYSTEM_SEARCH), else the pinned download.
#   kataglyphis_provision_appimagetool(<out_var> [DESTINATION <dir>] [VERSIONS_ENV <file>] [NO_SYSTEM_SEARCH])
function(kataglyphis_provision_appimagetool out_var)
  cmake_parse_arguments(
    KATAGLYPHIS_APPIMAGE
    "NO_SYSTEM_SEARCH"
    "DESTINATION;VERSIONS_ENV"
    ""
    ${ARGN})
  if(KATAGLYPHIS_APPIMAGE_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "kataglyphis_provision_appimagetool: unexpected argument(s) "
                        "'${KATAGLYPHIS_APPIMAGE_UNPARSED_ARGUMENTS}'")
  endif()

  if(DEFINED KATAGLYPHIS_APPIMAGETOOL
     AND NOT
         "${KATAGLYPHIS_APPIMAGETOOL}"
         STREQUAL
         "")
    if(NOT EXISTS "${KATAGLYPHIS_APPIMAGETOOL}")
      message(FATAL_ERROR "KataglyphisAppImage: KATAGLYPHIS_APPIMAGETOOL is set to "
                          "'${KATAGLYPHIS_APPIMAGETOOL}', which does not exist.")
    endif()
    set(${out_var}
        "${KATAGLYPHIS_APPIMAGETOOL}"
        PARENT_SCOPE)
    return()
  endif()

  # appimagetool is itself a Linux AppImage; a non-Linux host could not execute it.
  if(NOT CMAKE_HOST_UNIX)
    message(FATAL_ERROR "KataglyphisAppImage: AppImage packaging is Linux-only; this host is "
                        "'${CMAKE_HOST_SYSTEM_NAME}'. Guard the call with if(UNIX).")
  endif()

  if(NOT KATAGLYPHIS_APPIMAGE_NO_SYSTEM_SEARCH)
    find_program(KATAGLYPHIS_APPIMAGETOOL_SYSTEM NAMES appimagetool)
    if(KATAGLYPHIS_APPIMAGETOOL_SYSTEM)
      message(STATUS "KataglyphisAppImage: using provisioned appimagetool at ${KATAGLYPHIS_APPIMAGETOOL_SYSTEM}")
      set(${out_var}
          "${KATAGLYPHIS_APPIMAGETOOL_SYSTEM}"
          PARENT_SCOPE)
      return()
    endif()
  endif()

  if(NOT KATAGLYPHIS_APPIMAGE_DESTINATION)
    set(KATAGLYPHIS_APPIMAGE_DESTINATION "${CMAKE_BINARY_DIR}/_kataglyphis_appimagetool")
  endif()
  if(NOT KATAGLYPHIS_APPIMAGE_VERSIONS_ENV)
    set(KATAGLYPHIS_APPIMAGE_VERSIONS_ENV "${KATAGLYPHIS_VERSIONS_ENV}")
  endif()

  kataglyphis_appimagetool_pin(
    _kataglyphis_version
    _kataglyphis_asset
    _kataglyphis_sha
    VERSIONS_ENV
    "${KATAGLYPHIS_APPIMAGE_VERSIONS_ENV}")

  set(_kataglyphis_tool "${KATAGLYPHIS_APPIMAGE_DESTINATION}/${_kataglyphis_asset}")

  # Re-hash a previously verified file so a corrupted cache is caught, not reused.
  if(EXISTS "${_kataglyphis_tool}")
    file(SHA256 "${_kataglyphis_tool}" _kataglyphis_have_sha)
    if(_kataglyphis_have_sha STREQUAL _kataglyphis_sha)
      message(STATUS "KataglyphisAppImage: reusing verified ${_kataglyphis_tool}")
      set(${out_var}
          "${_kataglyphis_tool}"
          PARENT_SCOPE)
      return()
    endif()
    file(REMOVE "${_kataglyphis_tool}")
  endif()

  # The versioned tag, never `continuous` - see the TS1 note in versions.env.
  set(_kataglyphis_url
      "https://github.com/AppImage/appimagetool/releases/download/${_kataglyphis_version}/${_kataglyphis_asset}")

  file(MAKE_DIRECTORY "${KATAGLYPHIS_APPIMAGE_DESTINATION}")
  message(STATUS "KataglyphisAppImage: downloading pinned appimagetool ${_kataglyphis_version} (${_kataglyphis_asset})")

  # A .part path renamed only once verified; not EXPECTED_HASH, whose error skips STATUS and leaves rejected bytes behind.
  set(_kataglyphis_part "${_kataglyphis_tool}.part")
  file(REMOVE "${_kataglyphis_part}")
  file(
    DOWNLOAD "${_kataglyphis_url}" "${_kataglyphis_part}"
    TLS_VERIFY ON
    STATUS _kataglyphis_download_status
    LOG _kataglyphis_download_log)

  list(
    GET
    _kataglyphis_download_status
    0
    _kataglyphis_download_rc)
  list(
    GET
    _kataglyphis_download_status
    1
    _kataglyphis_download_msg)
  if(NOT
     _kataglyphis_download_rc
     EQUAL
     0)
    file(REMOVE "${_kataglyphis_part}")
    message(
      FATAL_ERROR
        "KataglyphisAppImage: downloading the pinned appimagetool FAILED.\n"
        "  url    : ${_kataglyphis_url}\n"
        "  status : ${_kataglyphis_download_rc} ${_kataglyphis_download_msg}\n"
        "AppImage packaging cannot proceed without the tool, and continuing with a warning would "
        "produce a package built by something nobody verified.\n"
        "download log:\n${_kataglyphis_download_log}")
  endif()

  file(SHA256 "${_kataglyphis_part}" _kataglyphis_actual_sha)
  if(NOT
     _kataglyphis_actual_sha
     STREQUAL
     _kataglyphis_sha)
    # Delete first, so a later configure cannot package with the rejected bytes.
    file(REMOVE "${_kataglyphis_part}")
    message(
      FATAL_ERROR
        "KataglyphisAppImage: appimagetool CHECKSUM MISMATCH - refusing to use it.\n"
        "  url      : ${_kataglyphis_url}\n"
        "  expected : ${_kataglyphis_sha}\n"
        "  actual   : ${_kataglyphis_actual_sha}\n"
        "This is either upstream re-uploading the asset in place (which is why the pin must name an "
        "immutable release tag and never `continuous`) or tampering. Both are stop conditions, not "
        "warnings. If the bump is intended, refresh APPIMAGETOOL_VERSION and every "
        "APPIMAGETOOL_*_SHA256 together in ${KATAGLYPHIS_APPIMAGE_VERSIONS_ENV}.")
  endif()

  file(RENAME "${_kataglyphis_part}" "${_kataglyphis_tool}")

  # An AppImage must read itself: docs/consumer-image-contract.md#executable-is-not-usable
  file(
    CHMOD
    "${_kataglyphis_tool}"
    PERMISSIONS
    OWNER_READ
    OWNER_WRITE
    OWNER_EXECUTE
    GROUP_READ
    GROUP_EXECUTE
    WORLD_READ
    WORLD_EXECUTE)

  message(STATUS "KataglyphisAppImage: verified appimagetool at ${_kataglyphis_tool}")
  set(${out_var}
      "${_kataglyphis_tool}"
      PARENT_SCOPE)
endfunction()
