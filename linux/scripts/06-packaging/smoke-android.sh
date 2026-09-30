#!/usr/bin/env bash
set -euo pipefail

# Android SDK/NDK smoke: sdkmanager, adb, NDK clang compiling a trivial object, build tools. No arguments.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

: "${ANDROID_SDK_ROOT:=/opt/android-sdk}"
# Fallbacks only; the image ENV from versions.env wins. Keep them equal to versions.env.
: "${ANDROID_NDK_VERSION:=29.0.14206865}"
: "${ANDROID_API_LEVEL:=34}"
: "${ANDROID_BUILD_TOOLS:=36.0.0}"

check_sdk_root() {
  # 1. Android SDK root
  echo "--- Android SDK root ---"
  if [ -d "${ANDROID_SDK_ROOT}" ]; then
    pass "Android SDK root exists: ${ANDROID_SDK_ROOT}"
  else
    fail "Android SDK root not found at ${ANDROID_SDK_ROOT}"
  fi
  echo ""
}

check_sdkmanager() {
  # 2. sdkmanager
  echo "--- sdkmanager ---"
  local sdkmanager="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"
  if [ -x "${sdkmanager}" ]; then
    local sm_ver
    sm_ver="$("${sdkmanager}" --version 2>/dev/null || true)"
    if [ -n "${sm_ver}" ]; then
      pass "sdkmanager --version: ${sm_ver}"
    else
      fail "sdkmanager failed to report version"
    fi
  else
    fail "sdkmanager not found at ${sdkmanager}"
  fi
  echo ""
}

check_adb() {
  # 3. adb
  echo "--- adb ---"
  local adb="${ANDROID_SDK_ROOT}/platform-tools/adb"
  if [ -x "${adb}" ]; then
    pass "adb found: ${adb}"
  else
    echo "  INFO: adb not found (only in full Android SDK install)"
  fi
  echo ""
}

check_ndk() {
  # 4. NDK
  echo "--- NDK ---"
  local ndk_dir="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"
  if [ -d "${ndk_dir}" ]; then
    pass "NDK ${ANDROID_NDK_VERSION} installed at ${ndk_dir}"

    local ndk_build="${ndk_dir}/ndk-build"
    if [ -x "${ndk_build}" ]; then
      pass "ndk-build exists"
    else
      fail "ndk-build not found at ${ndk_build}"
    fi

    # Check NDK toolchains exist
    local toolchain_dir="${ndk_dir}/toolchains/llvm/prebuilt/linux-x86_64"
    if [ -d "${toolchain_dir}" ]; then
      pass "NDK LLVM toolchain present"
      for target_arch in aarch64 x86_64 riscv64; do
        local cc="${toolchain_dir}/bin/${target_arch}-linux-android${ANDROID_API_LEVEL}-clang"
        if [ -x "${cc}" ]; then
          pass "NDK clang for ${target_arch}: ${cc}"
          # The NDK clang is an x86_64 host binary, so it runs everywhere; the object is target-arch.
          local ndk_tmp ndk_machine ndk_want
          ndk_tmp="$(mktemp -d)"
          if printf 'int f(void){return 1;}\n' | "${cc}" -x c - -c -o "${ndk_tmp}/a.o" 2>/dev/null; then
            ndk_machine="$(smoke_elf_machine_of "${ndk_tmp}/a.o" || true)"
            # smoke-common's arch map takes OCI names; the loop keys are uname names.
            ndk_want="$(smoke_elf_machine_grep "$(smoke_host_arch "${target_arch}")" 2>/dev/null || true)"
            if [ -z "${ndk_want}" ]; then
              # Never reach `case ... in *""*)`: it matches anything and would pass silently.
              fail "NDK clang ${target_arch}: no ELF-machine mapping for this arch, object not verified"
            else
              case "${ndk_machine}" in
                *"${ndk_want}"*)
                  pass "NDK clang ${target_arch}: compiles, object ELF machine=${ndk_machine}" ;;
                *)
                  fail "NDK clang ${target_arch}: object ELF machine '${ndk_machine}' does not match target" ;;
              esac
            fi
          else
            fail "NDK clang for ${target_arch} exists but cannot compile a trivial object"
          fi
          rm -rf "${ndk_tmp}"
        fi
      done
    else
      fail "NDK LLVM toolchain not found at ${toolchain_dir}"
    fi
  else
    fail "NDK ${ANDROID_NDK_VERSION} not found at ${ndk_dir}"
  fi
  echo ""
}

check_build_tools() {
  # 5. Build tools
  echo "--- Build tools ---"
  local build_tools="${ANDROID_SDK_ROOT}/build-tools/${ANDROID_BUILD_TOOLS}"
  if [ -d "${build_tools}" ]; then
    pass "Build tools ${ANDROID_BUILD_TOOLS} installed"
    for tool in aapt2 zipalign apksigner; do
      if [ -x "${build_tools}/${tool}" ]; then
        pass "  ${tool} found"
      else
        fail "  ${tool} not found in build-tools ${ANDROID_BUILD_TOOLS}"
      fi
    done
  else
    fail "Build tools ${ANDROID_BUILD_TOOLS} not found at ${build_tools}"
  fi
  echo ""
}

# Every SDK platform the image ships; the build-tools check reads only the main pin.
check_platforms() {
  echo "--- SDK platforms ---"
  local level dir
  for level in "${ANDROID_COMPILE_SDK:-}" "${ANDROID_EXTRA_COMPILE_SDK:-}"; do
    [ -n "${level}" ] || continue
    dir="${ANDROID_SDK_ROOT}/platforms/android-${level}"
    if [ -f "${dir}/android.jar" ]; then
      pass "Platform android-${level} installed"
    else
      fail "Platform android-${level} not found at ${dir}"
    fi
  done
  if [ -n "${ANDROID_EXTRA_BUILD_TOOLS:-}" ]; then
    if [ -x "${ANDROID_SDK_ROOT}/build-tools/${ANDROID_EXTRA_BUILD_TOOLS}/aapt2" ]; then
      pass "Build tools ${ANDROID_EXTRA_BUILD_TOOLS} installed"
    else
      fail "Build tools ${ANDROID_EXTRA_BUILD_TOOLS} not found in ${ANDROID_SDK_ROOT}/build-tools"
    fi
  fi
  echo ""
}

check_android_cmake() {
  # 6. CMake (Android)
  echo "--- Android CMake ---"
  local android_cmake="${ANDROID_SDK_ROOT}/cmake"
  if [ -d "${android_cmake}" ]; then
    local cmake_bin
    cmake_bin="$(find "${android_cmake}" -name "cmake" -type f 2>/dev/null | head -1 || true)"
    if [ -x "${cmake_bin}" ]; then
      local cmake_ver
      cmake_ver="$("${cmake_bin}" --version 2>/dev/null | head -1 || true)"
      pass "Android CMake: ${cmake_ver}"
    fi
  else
    echo "  INFO: Android CMake not found (optional)"
  fi
  echo ""
}

check_opencv() {
  echo "--- OpenCV (Android) ---"
  local opencv_prefix="${OPENCV_OUTPUT_DIR:-/opt/opencv5}"
  if [ -d "${opencv_prefix}" ]; then
    pass "OpenCV found at ${opencv_prefix}"
    # Built with BUILD_JAVA=OFF: Java wrappers here are JNI bindings nobody uses.
    if find "${opencv_prefix}" -name "libopencv_java*.so" -type f 2>/dev/null | grep -q .; then
      fail "OpenCV Java wrappers FOUND (should be NO — build with -DBUILD_JAVA=OFF)"
    else
      pass "OpenCV Java wrappers: NO (as expected)"
    fi
  else
    echo "  INFO: OpenCV not found in Android image (optional)"
  fi
  echo ""
}

# Read, never re-derived: android-sdk.sh owns it, and sourcing platform.sh here would change check_ndk's helpers.
_android_payload_off_marker=/opt/android/.android-payload-off

main() {
  echo "=== Android SDK/NDK Smoke Test ==="
  echo ""

  if [ -f "${_android_payload_off_marker}" ]; then
    echo "Android payload is OFF for this image:"
    cat "${_android_payload_off_marker}"
    echo ""
    local _check
    for _check in sdk_root sdkmanager adb ndk build_tools platforms android_cmake opencv; do
      echo "SKIP ${_check} (android payload off)"
    done
    echo ""
    smoke_summary
    return
  fi

  check_sdk_root
  check_sdkmanager
  check_adb
  check_ndk
  check_build_tools
  check_platforms
  check_android_cmake
  check_opencv
  smoke_summary
}

main "$@"
