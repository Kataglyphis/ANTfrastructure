#!/usr/bin/env bash
# Keep consumer failure symptoms together so diagnostics name the broken consumer workflow.

_consumer_contract_symptom() {
  local -A symptoms=(
    [ccache-dir]='the cache lands in the consumer checkout and flatpak-builder aborts: "Can'"'"'t initialize ccache use: Failed to set permissions of .../ccache.conf: Operation not permitted"'
    [sccache-dir]='the cache lands in the consumer checkout and flatpak-builder aborts: "Can'"'"'t initialize ccache use: Failed to set permissions of .../ccache.conf: Operation not permitted"'
    [rustup-tmp]='rustup dies with "could not create temp file ...: Permission denied (os error 13)" and Corrosion / cargokit / flutter_rust_bridge_codegen cannot run; redirecting the var does not help, the toolchains live there'
    [cargo-home]='every consumer has to pass -e CARGO_HOME=... to work around it'
    [android-home]='"flutter build apk" stops with "[!] No Android SDK found"; under CodeQL database create that surfaces three steps later as "bundle source directory not found"'
    [jdk]='Gradle stops the Android lane with "ERROR: JAVA_HOME is not set and no '"'"'java'"'"' command could be found in your PATH", and flutter doctor reports "No Java Development Kit (JDK) found" -- the SDK COPY leaves the source stage'"'"'s JDK behind in /usr/lib/jvm'
    [appimagetool]='appimagetool is an AppImage: it reads /proc/self/exe for its own squashfs offset, so a mode that is executable but not READABLE gives "Cannot open /proc/self/exe: Permission denied" and no .AppImage is produced'
    [dart-tool]='"flutter pub get" fails with "Cannot open file ... package_config.json (OS Error: Permission denied, errno = 13)"'
    [flutter-owner]='a root-owned path in a read-only overlay layer a consumer can neither chown, empty nor rename -- the only workaround is mounting a tmpfs over it'
    [flatpak-runtimes]='flatpak list --runtime returns 0 refs, so every run re-downloads seven org.freedesktop refs (~1.9 GB) -- the single largest download in a consumer build'
    [appimage-runtime]='appimagetool refetches runtime-<arch> from the type2-runtime continuous release on every build, so packaging hangs on GitHub being reachable'
    [web-lane-tools]='flutter_rust_bridge_codegen build-web cargo-installs wasm-pack (258 crates) and itself (174) from source in every run'
    [ort-crate-env]='an ort-sys build (OxidANT'"'"'s onnxruntime feature) statically links pyke'"'"'s ORT 1.28.0 from pyke'"'"'s CDN instead of the chain ORT, and ort load-dynamic opens whichever libonnxruntime.so the loader finds first'
    [chrome]='flutter doctor reports "Cannot find Chrome executable at google-chrome" and "flutter test --platform chrome" has no browser, so the web lane tests nothing in one'
    [android-emulator]='an Android lane has no device to install on: adb reports "no devices/emulators found" and every on-device test is skipped'
    [cargo-qa-tools]='every OxidANT security and coverage step cargo-installs cargo-audit, cargo-deny and cargo-tarpaulin from crates.io first, minutes of compiles per run'
    [free-threaded-python]='every X.Yt leg has uv download a free-threaded CPython first, its patch version unpinned'
    [lint-tools]='OrchestrANT'"'"'s coding bench reports "[shellcheck SKIPPED: not on PATH]" and "[hadolint SKIPPED: not on PATH]" on every row, so no bash or Dockerfile answer is linted'
    [uv-cache-seed]='the riscv64 Python lane'"'"'s uv sync of the test extra builds numpy, matplotlib, contourpy, pillow, line-profiler, psutil and pyyaml under QEMU: 108 min of a 6 h job'
    [gtk4-dev]='OxidANT'"'"'s GTK GUI stops in a gtk4-rs -sys build script ("The system library `graphene-gobject-1.0` required by crate `graphene-sys` was not found" on amd64, `gtk4` elsewhere), and uid 1001 cannot apt-get the dev package'
  )
  printf '%s' "${symptoms[${1:-_unknown}]:-no symptom recorded for this row}"
}

_consumer_versioned_verdict() {
  local row="$1" probe="$2" arch="$3" line _sc _hl
  case "${row}" in
        chrome)        line="$(_consumer_chrome_verdict "${row}" "${probe}" "$(_rt_versions_env_pin CHROME_FOR_TESTING_VERSION)")" ;;
        android-emulator)
                       line="$(_consumer_emulator_verdict "${row}" "${probe}" "$(_rt_versions_env_pin ANDROID_EMULATOR_VERSION)" \
                                 "android-$(_rt_versions_env_pin ANDROID_EMULATOR_API);google_apis;x86_64;r$(_rt_versions_env_pin ANDROID_EMULATOR_SYSIMG_REVISION)")" ;;
        cargo-qa-tools)
                       line="$(_consumer_cargo_qa_verdict "${row}" "${probe}" \
                                 "cargo-audit=$(_rt_versions_env_pin CARGO_AUDIT_VERSION) cargo-deny=$(_rt_versions_env_pin CARGO_DENY_VERSION) cargo-tarpaulin=$(_rt_versions_env_pin CARGO_TARPAULIN_VERSION)")" ;;
        free-threaded-python)
                       line="$(_consumer_free_threaded_verdict "${row}" "${probe}" "$(_rt_versions_env_pin PYTHON_VERSION)")" ;;
        lint-tools)    _sc="$(_rt_tool_pin SHELLCHECK_VERSION)"; _hl="$(_rt_tool_pin HADOLINT_VERSION)"
                       line="$(_consumer_lint_tools_verdict "${row}" "${probe}" "shellcheck=${_sc#v} hadolint=${_hl#v}")" ;;
        uv-cache-seed) line="$(_consumer_uv_seed_verdict "${row}" "${probe}" "${arch}")" ;;
        gtk4-dev)      line="$(_consumer_gtk4_verdict "${row}" "${probe}")" ;;
  esac
  printf '%s' "${line}"
}

_consumer_require_fact() {
  local probe="$1" row="$2" fact="$3" absent="$4"
  case "$(_consumer_contract_fact "${probe}" FACT "${fact}")" in
    yes) return 0 ;;
    no) printf 'BAD %s %s' "${row}" "${absent}" ;;
    *) printf 'NOFACT %s no FACT %s line' "${row}" "${fact}" ;;
  esac
  return 1
}

_consumer_version_matches() {
  local row="$1" have="$2" want="$3" subject="$4" empty_have="$5" empty_want="${6:-}"
  [ "${have}" != "${want}" ] || return 0
  printf 'BAD %s %s %s, the pin is %s' "${row}" "${subject}" "${have:-${empty_have}}" "${want:-${empty_want}}"
  return 1
}
