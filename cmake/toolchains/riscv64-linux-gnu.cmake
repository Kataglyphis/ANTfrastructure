# riscv64 cross toolchain for the family amd64 image; riscv64_cross_env (linux/scripts/lib/riscv64-cross.sh) must run first.
# See docs/riscv64-cross-test-lanes.md
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

foreach(
  _rv_var
  RISCV64_SYSROOT
  RISCV64_CROSS_BIN
  RISCV64_CROSS_LLVM
  RISCV64_PKG_CONFIG_LIBDIR)
  if(NOT DEFINED ENV{${_rv_var}})
    message(
      FATAL_ERROR
        "riscv64 toolchain: ${_rv_var} is unset; source linux/scripts/lib/riscv64-cross.sh and call riscv64_cross_env")
  endif()
endforeach()

set(CMAKE_SYSROOT "$ENV{RISCV64_SYSROOT}")
set(CMAKE_LIBRARY_ARCHITECTURE riscv64-linux-gnu)
set(CMAKE_C_COMPILER "$ENV{RISCV64_CROSS_BIN}/riscv64-linux-gnu-clang")
set(CMAKE_CXX_COMPILER "$ENV{RISCV64_CROSS_BIN}/riscv64-linux-gnu-clang++")
# The image's own clang-scan-deps has no riscv64 backend, and the /opt/gcc-16.2.0 binutils links dangle.
set(CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS
    "$ENV{RISCV64_CROSS_LLVM}/bin/clang-scan-deps"
    CACHE FILEPATH "")
foreach(
  _rv_tool
  AR
  RANLIB
  NM
  OBJCOPY
  OBJDUMP
  READELF
  STRIP)
  string(TOLOWER "${_rv_tool}" _rv_name)
  set(CMAKE_${_rv_tool}
      "$ENV{RISCV64_CROSS_LLVM}/bin/llvm-${_rv_name}"
      CACHE FILEPATH "")
endforeach()

# binfmt runs riscv64 binaries directly; the emulator only lets try_run and test discovery execute them.
set(CMAKE_CROSSCOMPILING_EMULATOR /usr/bin/env)

set(CMAKE_FIND_ROOT_PATH "$ENV{RISCV64_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# A sourced Vulkan setup-env names the x86_64 SDK, which the sysroot does not have.
set(ENV{VULKAN_SDK} /opt/vulkan/active)
set(ENV{PKG_CONFIG_SYSROOT_DIR} "$ENV{RISCV64_SYSROOT}")
set(ENV{PKG_CONFIG_LIBDIR} "$ENV{RISCV64_PKG_CONFIG_LIBDIR}")
unset(ENV{PKG_CONFIG_PATH})
