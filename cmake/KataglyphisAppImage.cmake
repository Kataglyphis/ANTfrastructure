# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# appimagetool, provisioned the way this repo already provisions it everywhere
# else: from an IMMUTABLE release tag, against a recorded SHA256, failing the
# configure step when either the download or the checksum does not hold.
#
# What this replaces in the consumers: BeschleunigerBallett and AccelerANTgine
# each download appimagetool from the MUTABLE `continuous` release tag with no
# EXPECTED_HASH at all, and report a failure with message(WARNING) - so a
# tampered, truncated or simply absent tool produces a warning nobody reads and
# a build that carries on to package with whatever it got. Both properties are
# wrong, and both are already solved here:
#
#   * linux/scripts/01-core/versions.env holds APPIMAGETOOL_VERSION plus one
#     SHA256 per supported host arch. It is the single place a bump happens, and
#     it carries the note explaining why `continuous` is banned (its assets are
#     re-uploaded in place, which once surfaced as a tamper-shaped mismatch).
#   * linux/scripts/02-toolchain/packaging-deps.sh installs the tool into the
#     images from exactly those pins, checksum-verified.
#
# So this module reads the SAME pin file rather than restating the values, and
# prefers an already-provisioned appimagetool (inside a ContainerHub image there
# is one on PATH and it got there through the verified path above) before it
# downloads anything itself.
#
# There is deliberately NO warn-and-continue branch. A packaging step that
# cannot get a verified tool has to stop.

include_guard(GLOBAL)

# The pin file. Resolved relative to THIS module so it is correct both in this
# repo and in a consumer that has third_party/ContainerHub/cmake on
# CMAKE_MODULE_PATH. Override only to test against a different pin set.
set(KATAGLYPHIS_VERSIONS_ENV
    "${CMAKE_CURRENT_LIST_DIR}/../linux/scripts/01-core/versions.env"
    CACHE FILEPATH "ContainerHub versions.env holding the appimagetool pins")

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
        "This module reads ContainerHub's linux/scripts/01-core/versions.env. If the ContainerHub "
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

# Resolves the pinned appimagetool release for a host architecture.
#
#   kataglyphis_appimagetool_pin(<out_version> <out_asset> <out_sha256>
#                                [ARCH <uname-m value>]
#                                [VERSIONS_ENV <file>])
#
# ARCH defaults to CMAKE_HOST_SYSTEM_PROCESSOR: the tool runs on the machine
# doing the build, not on the target, so a cross build still needs the host's
# asset. Exposed separately from the provisioning function so a consumer (and
# this repo's own checks) can assert against the pins without a network round
# trip.
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
    # CMAKE_HOST_SYSTEM_PROCESSOR is only filled in by project(); in script mode
    # (cmake -P, which is how this module gets exercised standalone) it is
    # EMPTY, and without this fallback the arch dispatch below reports "no
    # pinned asset for host architecture ''" - a real dead end that looks like
    # an unsupported platform. uname -m is what packaging-deps.sh keys on too.
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

  # The arms mirror packaging-deps.sh ensure_appimagetool one for one, so the
  # two provisioning paths cannot disagree about which asset an arch gets.
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

# Makes a verified appimagetool available and returns its path.
#
#   kataglyphis_provision_appimagetool(<out_var>
#                                      [DESTINATION <dir>]
#                                      [VERSIONS_ENV <file>]
#                                      [NO_SYSTEM_SEARCH])
#
# Resolution order:
#   1. -DKATAGLYPHIS_APPIMAGETOOL=<path>   an explicit, caller-owned tool
#   2. appimagetool on PATH                inside a ContainerHub image this is
#                                          the checksum-verified one that
#                                          packaging-deps.sh installed
#                                          (NO_SYSTEM_SEARCH skips this)
#   3. download the pinned asset           EXPECTED_HASH, TLS on, fatal on any
#                                          failure
#
# DESTINATION defaults to ${CMAKE_BINARY_DIR}/_kataglyphis_appimagetool.
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

  # appimagetool IS an AppImage: a Linux ELF that mounts its own squashfs. There
  # is nothing to provision on a non-Linux host, and pretending otherwise would
  # hand the caller a file it cannot execute.
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

  # A previous configure already verified this exact file; re-checking the hash
  # is cheap and means a corrupted cache is caught instead of reused.
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

  # Download to a .part path and only publish it under the real name after the
  # checksum holds, so an interrupted or rejected download can never be picked
  # up as a provisioned tool by the next configure.
  #
  # The verification is written out rather than delegated to file(DOWNLOAD)'s
  # EXPECTED_HASH for two reasons, both observed: EXPECTED_HASH raises its own
  # error that bypasses STATUS entirely (so none of the guidance below would
  # ever be printed), and it leaves the rejected bytes sitting at the
  # destination path.
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
    # Delete first: rejected bytes left on disk are what turn one bad configure
    # into a build that silently packages with garbage later.
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

  # mktemp-style 0600 would ship a tool that cannot read ITSELF, and an AppImage
  # has to (docs/consumer-image-contract.md#executable-is-not-usable).
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
