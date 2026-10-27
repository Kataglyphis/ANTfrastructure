#!/usr/bin/env bash
# Builds real x64/arm64 PE fixtures with icons; does not run either Windows executable.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
# shellcheck source=linux/scripts/lib/pe-icon-tools.sh
source "${TESTS_DIR}/../lib/pe-icon-tools.sh"
ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
HUB_CMAKE="$(cmake_fixture_module_root --native)"
_work="$(mktemp -d "${TMPDIR:-/tmp}/icon fixture.XXXXXX")"
trap 'rm -rf "${_work}"' EXIT

_rc="$(pe_icon_find_tool llvm-rc)"
_link="$(pe_icon_find_tool lld-link)"
_readobj="$(pe_icon_find_tool llvm-readobj)"
_clang="$(pe_icon_find_clang)"
_rust="$(command -v rustc)"
t_skip_unless "llvm-rc" test -x "${_rc}"
t_skip_unless "lld-link" test -x "${_link}"
t_skip_unless "llvm-readobj" test -x "${_readobj}"
t_skip_unless "clang" test -x "${_clang}"
t_skip_unless "rustc" test -x "${_rust}"
t_skip_unless "ninja" command -v ninja
t_skip_unless "PowerShell 7" command -v pwsh

# A valid ICO wraps the tracked 256-pixel PNG, keeping the fixture independent of a host GUI.
python3 -c 'import pathlib,struct,sys; data=pathlib.Path(sys.argv[1]).read_bytes(); pathlib.Path(sys.argv[2]).write_bytes(struct.pack("<HHHBBBBHHII",0,1,1,0,0,0,0,1,32,len(data),22)+data)' \
  "${ROOT}/images/logo.png" "${_work}/project.ico"
python3 -c 'import pathlib,struct,sys,zlib; chunk=lambda t,d: struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)); p=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",1,1,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(b"\0\xff\0\0\xff"))+chunk(b"IEND",b""); pathlib.Path(sys.argv[1]).write_bytes(p); pathlib.Path(sys.argv[2]).write_bytes(struct.pack("<HHHBBBBHHII",0,1,1,1,1,0,0,1,32,len(p),22)+p)' \
  "${_work}/second.png" "${_work}/second.ico"
printf 'int main(void) { return 0; }\n' > "${_work}/main.c"
cat > "${_work}/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.20)
project(icon LANGUAGES C RC)
include("${HUB_CMAKE}/CPackCommon.cmake")
add_executable(icon main.c)
kataglyphis_add_windows_icon(icon "${_work}/project.ico")
EOF

_run_cmake_pe() {
  local arch="$1" target="$2" dir="${_work}/cmake-$1"
  cmake -S "${_work}" -B "${dir}" -G Ninja -DCMAKE_SYSTEM_NAME=Windows \
    "-DCMAKE_C_COMPILER=${_clang}" "-DCMAKE_C_COMPILER_TARGET=${target}" "-DCMAKE_RC_COMPILER=${_rc}" \
    -DCMAKE_C_COMPILER_WORKS=TRUE -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE=-O2 -DCMAKE_C_STANDARD_LIBRARIES= \
    "-DCMAKE_EXE_LINKER_FLAGS=-nostdlib -fuse-ld=lld -Wl,/nodefaultlib -Wl,/entry:main -Wl,/subsystem:console" \
    "-DCMAKE_LINKER=${_link}" || return
  cmake --build "${dir}" || return
  "${_readobj}" --coff-resources "${dir}/icon.exe" > "${_work}/cmake-${arch}.txt"
}

_pe_contains_png() {
  python3 -c 'import pathlib,sys; sys.exit(0 if pathlib.Path(sys.argv[2]).read_bytes() in pathlib.Path(sys.argv[1]).read_bytes() else 1)' "$1" "$2"
}

_assert_resource_pe() {
  local name="$1" arch="$2" resource="$3" png="$4" exe="${_work}/$1-$2.exe"
  t_assert_rc 0 "${_link}" "/out:${exe}" /entry:main /subsystem:console /nodefaultlib \
    "${_work}/${arch}.obj" "${resource}"
  "${_readobj}" --coff-resources "${exe}" > "${_work}/${name}-${arch}.txt"
  t_assert_grep "${_work}/${name}-${arch}.txt" 'GROUP_ICON|GroupIcon|GROUP ICON'
  t_assert_ok _pe_contains_png "${exe}" "${png}"
}

t_case "CMake embeds the ICO into a real x64 PE"
t_assert_rc 0 _run_cmake_pe x64 x86_64-pc-windows-msvc
t_assert_grep "${_work}/cmake-x64.txt" 'GROUP_ICON|GroupIcon|GROUP ICON'
t_assert_ok _pe_contains_png "${_work}/cmake-x64/icon.exe" "${ROOT}/images/logo.png"
t_case "CMake embeds the ICO into a real arm64 PE"
t_assert_rc 0 _run_cmake_pe arm64 aarch64-pc-windows-msvc
t_assert_grep "${_work}/cmake-arm64.txt" 'GROUP_ICON|GroupIcon|GROUP ICON'
t_assert_ok _pe_contains_png "${_work}/cmake-arm64/icon.exe" "${ROOT}/images/logo.png"

cat > "${_work}/rust-fixture.rs" <<EOF
#[path = "${ROOT}/shared/rust/windows_icon.rs"]
mod windows_icon;
fn main() {
    windows_icon::add_windows_icon("icon", std::path::Path::new("${_work}/project.ico"));
    windows_icon::add_windows_icon("second", std::path::Path::new("${_work}/second.ico"));
}
EOF
t_case "the shared Rust build helper emits a bin-scoped compiled icon resource"
t_assert_rc 0 "${_rust}" --edition=2024 "${_work}/rust-fixture.rs" -o "${_work}/rust-fixture"
mkdir -p "${_work}/rust"
_run_rust_icon() {
  CARGO_CFG_TARGET_OS=windows CARGO_CFG_TARGET_ENV=msvc OUT_DIR="${_work}/rust" LLVM_RC="${_rc}" "${_work}/rust-fixture" > "${_work}/rust-output.txt"
}
t_assert_rc 0 _run_rust_icon
t_assert_grep "${_work}/rust-output.txt" '^cargo:rustc-link-arg-bin=icon=.*icon-icon\.res$'
t_assert_grep "${_work}/rust-output.txt" '^cargo:rustc-link-arg-bin=second=.*second-icon\.res$'
t_assert_grep "${_work}/rust-output.txt" '^cargo:rerun-if-changed=.*project\.ico$'
t_assert_grep "${_work}/rust-output.txt" '^cargo:rerun-if-changed=.*second\.ico$'
t_assert_fails cmp "${_work}/rust/icon-icon.res" "${_work}/rust/second-icon.res"
for _pair in 'x64 x86_64-pc-windows-msvc' 'arm64 aarch64-pc-windows-msvc'; do
  read -r _arch _target <<< "${_pair}"
  t_case "Rust resource links into a real ${_arch} PE"
  t_assert_rc 0 "${_clang}" "--target=${_target}" -c "${_work}/main.c" -o "${_work}/${_arch}.obj"
  _assert_resource_pe rust "${_arch}" "${_work}/rust/icon-icon.res" "${ROOT}/images/logo.png"
  _assert_resource_pe rust-second "${_arch}" "${_work}/rust/second-icon.res" "${_work}/second.png"
done

t_case "PowerShell generates a fresh ICO resource for the Python app launcher"
_invoke_pwsh_icon() {
  PE_ICON_MODULE="${ROOT}/windows/scripts/modules/WindowsIcon.Common.psm1" PE_ICON_SOURCE="${ROOT}/images/logo.png" \
    PE_ICON_WORK="$1" PE_ICON_RC="$2" pwsh -NoProfile -Command \
    '$ErrorActionPreference = "Stop"; Import-Module -Name $env:PE_ICON_MODULE; if ($IsLinux) { & (Get-Module WindowsIcon.Common) { function script:Read-MsixLogo { param($Path) $image = [pscustomobject]@{}; $image | Add-Member ScriptMethod Dispose {}; return $image } } }; New-WindowsIconResource -PngPath $env:PE_ICON_SOURCE -WorkDir $env:PE_ICON_WORK -ResourceCompiler $env:PE_ICON_RC'
}
_run_pwsh_icon() {
  _invoke_pwsh_icon "${_work}/pwsh icons" "${_rc}" > "${_work}/pwsh-output.txt"
}
t_assert_rc 0 _run_pwsh_icon
_pwsh_res="$(tail -n 1 "${_work}/pwsh-output.txt" | tr -d '\r')"
t_assert_ok test -s "${_pwsh_res}"
for _arch in x64 arm64; do
  t_case "Python launcher resource links into a real ${_arch} PE"
  _assert_resource_pe pwsh "${_arch}" "${_pwsh_res}" "${ROOT}/images/logo.png"
done

_build_clang_launcher() {
  local arch="$1" target="$2"
  PATH="$(dirname "${_link}"):${PATH}" "${_clang}" --driver-mode=cl /nologo /O2 /MT /W3 \
    "/clang:--target=${target}" /clang:-fuse-ld=lld "/Fo${_work}/launcher-${arch}.obj" "/Fe${_work}/launcher-${arch}.exe" \
    "${_work}/main.c" /link /SUBSYSTEM:CONSOLE /ENTRY:main /NODEFAULTLIB "${_pwsh_res}"
}
for _pair in 'x64 x86_64-pc-windows-msvc' 'arm64 aarch64-pc-windows-msvc'; do
  read -r _arch _target <<< "${_pair}"
  t_case "clang-cl accepts the Python launcher resource for ${_arch}"
  t_assert_rc 0 _build_clang_launcher "${_arch}" "${_target}"
  t_assert_ok _pe_contains_png "${_work}/launcher-${_arch}.exe" "${ROOT}/images/logo.png"
done

t_case "PowerShell refuses a compiler failure or a success without output"
_run_pwsh_broken() {
  _invoke_pwsh_icon "${_work}/pwsh broken" "$1"
}
t_assert_fails _run_pwsh_broken /bin/false
t_assert_fails _run_pwsh_broken /bin/true
cat > "${_work}/failing-rc" <<'EOF'
#!/bin/sh
printf broken > "$2"
exit 7
EOF
chmod +x "${_work}/failing-rc"
t_assert_fails _run_pwsh_broken "${_work}/failing-rc"
t_assert_eq 0 "$(find "${_work}/pwsh broken" -type f | wc -l | tr -d ' ')" "failed compiler inputs and stale resources are cleaned"

t_case "a failing resource compiler cannot reuse a stale resource"
_run_broken_rc() {
  CARGO_CFG_TARGET_OS=windows CARGO_CFG_TARGET_ENV=msvc OUT_DIR="${_work}/rust" LLVM_RC=/bin/false "${_work}/rust-fixture"
}
t_assert_fails _run_broken_rc
t_assert_fails test -e "${_work}/rust/icon-icon.res"

t_case "success without a fresh resource is also a failure"
_run_empty_rc() {
  CARGO_CFG_TARGET_OS=windows CARGO_CFG_TARGET_ENV=msvc OUT_DIR="${_work}/rust" LLVM_RC=/bin/true "${_work}/rust-fixture"
}
t_assert_fails _run_empty_rc
t_assert_fails test -e "${_work}/rust/icon-icon.res"

t_case "non-Windows targets do not need the resource compiler"
_run_nonwindows() {
  CARGO_CFG_TARGET_OS=linux OUT_DIR="${_work}/rust" LLVM_RC=/bin/false "${_work}/rust-fixture" > "${_work}/linux-output.txt"
}
t_assert_ok _run_nonwindows
t_assert_no_grep "${_work}/linux-output.txt" '^cargo:rustc-link-arg-bin='

t_summary
