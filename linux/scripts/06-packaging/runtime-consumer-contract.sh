#!/usr/bin/env bash
# Keep consumer failure symptoms together so diagnostics name the broken consumer workflow.

# Calls stay unconditional so strict lookup/printf failures retain their original shell behavior.
_consumer_collect_required_facts() {
  local _ccrf_probe="$1"
  local -n _ccrf_verdict="$2"
  local _ccrf_row="$3" _ccrf_message="$4" _ccrf_destination _ccrf_kind _ccrf_key _ccrf_value _ccrf_policy _ccrf_missing=0
  shift 4
  _ccrf_verdict="continue"
  while [ "$#" -gt 0 ]; do
    _ccrf_destination="$1"; _ccrf_kind="$2"; _ccrf_key="$3"; _ccrf_policy="$4"
    shift 4
    _ccrf_value="$(_consumer_contract_fact "${_ccrf_probe}" "${_ccrf_kind}" "${_ccrf_key}")"
    printf -v "${_ccrf_destination}" '%s' "${_ccrf_value}"
    if [ "${_ccrf_policy}" = required ] && [ -z "${_ccrf_value}" ]; then _ccrf_missing=1; fi
  done
  if [ "${_ccrf_missing}" = 1 ]; then
    printf 'NOFACT %s %s' "${_ccrf_row}" "${_ccrf_message}"
    _ccrf_verdict=$?
  fi
  return 0
}

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

_consumer_required_facts_continue() {
  case "$1" in continue) return 0 ;; *) return 1 ;; esac
}

# Outside /workspace, the consumer's bind-mounted checkout, and writable by the image user.
_consumer_dir_verdict() {
  local row="$1" val="$2" write="$3"
  case "${write}" in
    yes|no) ;;
    *) printf 'NOFACT %s no WRITE line\n' "${row}"; return 0 ;;
  esac
  case "${val}" in
    "")          printf 'BAD %s the variable is unset, so the consumer inherits no location at all\n' "${row}" ;;
    /workspace*) printf 'BAD %s points into the bind-mounted checkout: %s\n' "${row}" "${val}" ;;
    *)           if [ "${write}" = yes ]; then
                   printf 'OK %s %s\n' "${row}" "${val}"
                 else
                   printf 'BAD %s not writable by the image user: %s\n' "${row}" "${val}"
                 fi ;;
  esac
}

# An exemption re-proves itself from the row's own fact; a missing fact is NOFACT, never a grant.
_consumer_exempt_verdict() {
  case "$3" in
    yes) printf 'STALE %s FACT %s says it IS present on %s -- delete the %s:%s arm from _consumer_contract_exempt' "$1" "$4" "$2" "$2" "$1" ;;
    no)  printf 'EXEMPT %s' "$1" ;;
    *)   printf 'NOFACT %s no FACT %s, so the exemption cannot be re-checked' "$1" "$4" ;;
  esac
}

# Executable-but-unreadable runs for root only; the probe answers as the shipped image user.
_consumer_tool_verdict() {
  _consumer_tooling_verdict tool "$@"
}

_consumer_jdk_verdict() {
  _consumer_tooling_verdict jdk "$@"
}

_consumer_tooling_verdict() {
  local kind="$1" row="$2" probe="$3" missing required_verdict
  local path readable home onpath javac
  local -a facts=()
  case "${kind}" in
    tool)
      missing='no FACT appimagetool-readable line'
      facts=(path ENV appimagetool optional readable FACT appimagetool-readable required) ;;
    jdk)
      missing='no FACT java-on-path / FACT javac line'
      facts=(home ENV java-home optional onpath FACT java-on-path required javac FACT javac required) ;;
  esac
  _consumer_collect_required_facts "${probe}" required_verdict "${row}" "${missing}" "${facts[@]}"
  _consumer_required_facts_continue "${required_verdict}" || return "${required_verdict}"
  case "${kind}" in
    tool)
      if [ -z "${path}" ]; then
        printf 'BAD %s appimagetool is not on PATH at all' "${row}"
      elif [ "${readable}" != yes ]; then
        printf 'BAD %s %s is not readable by the image user' "${row}" "${path}"
      else
        printf 'OK %s %s readable' "${row}" "${path}"
      fi ;;
    jdk)
      if [ "${onpath}" != yes ]; then
        printf 'BAD %s no java on PATH' "${row}"
      elif [ -z "${home}" ]; then
        printf 'BAD %s java runs but JAVA_HOME is unset, which is what Gradle reads' "${row}"
      elif [ "${javac}" != yes ]; then
        printf 'BAD %s JAVA_HOME=%s has no bin/javac -- a JRE cannot compile' "${row}" "${home}"
      else
        printf 'OK %s java + JAVA_HOME=%s with javac' "${row}" "${home}"
      fi ;;
  esac
}

_consumer_android_verdict() {
  local row="$1" val root dir onpath off required_verdict
  # The NDK is linux-x86_64 only; prune-host-payload.sh (or android-sdk.sh on a foreign host) writes the marker.
  _consumer_collect_required_facts "$2" required_verdict "${row}" 'no FACT android-payload-off line' \
    off FACT android-payload-off required
  _consumer_required_facts_continue "${required_verdict}" || return 0
  _consumer_collect_required_facts "$2" required_verdict "${row}" '' \
    val ENV android-home optional root ENV android-sdk-root optional
  if [ "${off}" = yes ]; then
    # An empty /opt/android-sdk behind ANDROID_HOME is the same "No Android SDK found", one probe later.
    if [ -n "${val}" ] || [ -n "${root}" ]; then
      printf 'BAD %s ANDROID_HOME=%s / ANDROID_SDK_ROOT=%s while /opt/android/.android-payload-off says the image ships no SDK' \
        "${row}" "${val:-<unset>}" "${root:-<unset>}"
    else
      printf 'SKIP %s the android payload is off for this image (/opt/android/.android-payload-off)' "${row}"
    fi
    return 0
  fi
  _consumer_collect_required_facts "$2" required_verdict "${row}" 'no DIR android-platform-tools / FACT android-path line' \
    dir DIR android-platform-tools required onpath FACT android-path required
  _consumer_required_facts_continue "${required_verdict}" || return "${required_verdict}"
  if [ -z "${val}" ] || [ -z "${root}" ]; then
    printf 'BAD %s ANDROID_HOME=%s / ANDROID_SDK_ROOT=%s while the SDK ships in the image' "${row}" "${val:-<unset>}" "${root:-<unset>}"
  elif [ "${dir}" != yes ]; then
    printf 'BAD %s %s/platform-tools does not exist' "${row}" "${val}"
  elif [ "${onpath}" != yes ]; then
    printf 'BAD %s neither %s/platform-tools nor cmdline-tools/latest/bin is on PATH' "${row}" "${val}"
  else
    printf 'OK %s %s' "${row}" "${val}"
  fi
}

# A missing count is NOFACT, not zero: the defect is root writing into the tree after the COPY.
_consumer_owner_verdict() {
  local row="$1" n
  n="$(_consumer_contract_fact "$2" FACT flutter-foreign)"
  if [ -z "${n}" ]; then
    printf 'NOFACT %s no FACT flutter-foreign line' "${row}"
  elif [ "${n}" != 0 ]; then
    printf 'BAD %s %s path(s) under /opt/flutter are not owned by the runtime uid: %s' "${row}" "${n}" \
      "$(_consumer_contract_fact "$2" FACT flutter-foreign-examples)"
  else
    printf 'OK %s every path under /opt/flutter belongs to the runtime uid' "${row}"
  fi
}

# EMPTY when ort-sys and load-dynamic both resolve the chain ORT. docs/consumer-image-contract.md#the-ort-crate-links-the-chain-onnx-runtime
_consumer_ort_env_problem() {
  local p="$1" lreal dreal v
  lreal="$(_consumer_contract_fact "${p}" FACT ort-lib-real)"
  dreal="$(_consumer_contract_fact "${p}" FACT ort-dylib-real)"
  case "${lreal}" in
    /usr/local/lib/onnxruntime-cpu/lib|/usr/local/lib/onnxruntime-gpu/lib) ;;
    *) printf 'ORT_LIB_LOCATION (%s) resolves to %s, not the chain ORT lib dir' \
         "$(_consumer_contract_fact "${p}" ENV ort-lib-location)" "${lreal:-nothing}"; return 0 ;;
  esac
  if [ "$(_consumer_contract_fact "${p}" FACT ort-link-lib)" != yes ]; then
    printf '%s has no libonnxruntime.so for ort-sys to link' "${lreal}"
    return 0
  fi
  case "${dreal}" in
    "${lreal}"/libonnxruntime.so*) ;;
    *) printf 'ORT_DYLIB_PATH (%s) resolves to %s, not a chain libonnxruntime.so' \
         "$(_consumer_contract_fact "${p}" ENV ort-dylib-path)" "${dreal:-nothing}"; return 0 ;;
  esac
  for v in ort-prefer-dynamic ort-skip-download; do
    case "$(_consumer_contract_fact "${p}" ENV "${v}" | tr '[:upper:]' '[:lower:]')" in
      1|true) ;;
      *) printf 'ENV %s is "%s", not 1' "${v}" "$(_consumer_contract_fact "${p}" ENV "${v}")"; return 0 ;;
    esac
  done
  v="$(_consumer_contract_fact "${p}" ENV ort-lib-path)"
  if [ "${v}" != '<unset>' ]; then
    printf 'ORT_LIB_PATH is set (%s), and ort-sys reads it before ORT_LIB_LOCATION, even empty' "${v}"
    return 0
  fi
  case "$(_consumer_contract_fact "${p}" ENV cargo-net-offline | tr '[:upper:]' '[:lower:]')" in
    '<unset>'|1|true) ;;
    *) printf 'CARGO_NET_OFFLINE is falsy (set, and not 1/true), and ort-sys reads it before ORT_SKIP_DOWNLOAD' ;;
  esac
}

_consumer_ort_env_verdict() {
  local row="$1" problem
  if [ "$(_consumer_contract_fact "$2" FACT ort-probe)" != yes ]; then
    printf 'NOFACT %s no FACT ort-probe line' "${row}"
    return 0
  fi
  problem="$(_consumer_ort_env_problem "$2")"
  if [ -n "${problem}" ]; then
    printf 'BAD %s %s' "${row}" "${problem}"
  else
    printf 'OK %s ORT_LIB_LOCATION -> %s, dynamic link, download disarmed' "${row}" \
      "$(_consumer_contract_fact "$2" FACT ort-lib-real)"
  fi
}

# CON65's three tools at their pins: docs/consumer-image-contract.md#the-cargo-qa-tools
_consumer_cargo_qa_verdict() {
  local row="$1" p="$2" pins="$3" have
  case "$(_consumer_contract_fact "${p}" FACT cargo-qa-tools)" in
    yes|no) ;;
    *) printf 'NOFACT %s no FACT cargo-qa-tools line' "${row}"; return 0 ;;
  esac
  have="$(_consumer_contract_fact "${p}" FACT cargo-qa-tools-versions)"
  if [ "${have}" = "${pins}" ]; then
    printf 'OK %s %s' "${row}" "${have}"
  else
    printf 'BAD %s the image has %s, the pins are %s' "${row}" "${have:-nothing}" "${pins}"
  fi
}

# CON66's interpreter: PYTHON_VERSION, the GIL really off, and the toolchain's source build. docs/consumer-image-contract.md#the-free-threaded-python
_consumer_free_threaded_verdict() {
  _consumer_versioned_contract_verdict free "$@"
}

# A tool-pins.env pin, for the rows whose tools the torch stage installs from it (CON83).
_rt_tool_pin() {
  _rt_env_pin tool-pins.env "$1"
}

# CON83's lint tools on PATH at their pins: docs/consumer-image-contract.md#shellcheck-and-hadolint
_consumer_lint_tools_verdict() {
  _consumer_versioned_contract_verdict lint "$@"
}

_consumer_versioned_contract_verdict() {
  local kind row probe want have key missing build release verdict
  kind="$1"
  row="$2"
  probe="$3"
  want="$4"
  if [ "${kind}" = free ]; then
    key=free-threaded-python
    release="${want}"
    want="${release} gil=False"
    missing='no FACT free-threaded-python line'
  else
    key=lint-tools
    missing='no FACT lint-tools line'
  fi
  have="$(_consumer_contract_fact "${probe}" FACT "${key}")"
  if [ "${kind}" = free ]; then
    build="$(_consumer_contract_fact "${probe}" FACT free-threaded-python-build)"
  fi
  if [ -z "${have}" ]; then
    verdict="NOFACT ${row} ${missing}"
  elif [ "${have}" != "${want}" ]; then
    if [ "${kind}" = free ]; then
      verdict="BAD ${row} python3.*t reports ${have}, expected ${want}"
    else
      verdict="BAD ${row} the image has ${have}, the pins are ${want}"
    fi
  elif [ "${kind}" = free ]; then
    # A python-build-standalone tree reports its own prefix; a missing stdlib module leaves its ImportError here.
    if [ "${build}" != 'prefix=/opt/python-freethreaded Py_GIL_DISABLED=1' ]; then
      verdict="BAD ${row} python3.*t is not the source build in /opt/python-freethreaded with its stdlib: ${build:-no FACT free-threaded-python-build line}"
    else
      verdict="OK ${row} CPython ${release} without the GIL, built from source in /opt/python-freethreaded"
    fi
  else
    verdict="OK ${row} ${have}"
  fi
  printf '%s' "${verdict}"
}

# CON83's seed, read through its own verify: docs/consumer-image-contract.md#the-riscv64-uv-cache-seed
_consumer_uv_seed_verdict() {
  local row="$1" arch="$3" env have
  env="$(_consumer_contract_fact "$2" ENV uv-cache-seed)"
  have="$(_consumer_contract_fact "$2" FACT uv-cache-seed)"
  if [ -z "${have}" ]; then
    printf 'NOFACT %s no FACT uv-cache-seed line' "${row}"
  elif [ "${env}" != /opt/uv-cache-seed ]; then
    printf 'BAD %s PYTHON_UV_CACHE_SEED is "%s", not /opt/uv-cache-seed' "${row}" "${env}"
  elif [ "${arch}" = riscv64 ]; then
    case "${have}" in
      "[uv-cache-seed] seeded for riscv64: "*", proved") printf 'OK %s %s' "${row}" "${have#*seeded for riscv64: }" ;;
      *) printf 'BAD %s the riscv64 seed does not verify: %s' "${row}" "${have}" ;;
    esac
  else
    case "${have}" in
      "[uv-cache-seed] not seeded: "*) printf 'OK %s not seeded on %s, by its record' "${row}" "${arch}" ;;
      *) printf 'BAD %s the %s record is not a "not seeded" one: %s' "${row}" "${arch}" "${have}" ;;
    esac
  fi
}

# CON129's GTK 4, read through the package stage's own gate: docs/consumer-image-contract.md#gtk-4-for-gtk4-rs
_consumer_gtk4_verdict() {
  local row="$1" have
  have="$(_consumer_contract_fact "$2" FACT gtk4-dev)"
  case "${have}" in
    '')           printf 'NOFACT %s no FACT gtk4-dev line' "${row}" ;;
    "OK: gtk4 "*) printf 'OK %s %s' "${row}" "${have#OK: }" ;;
    *)            printf 'BAD %s %s' "${row}" "${have}" ;;
  esac
}

# Pure verdicts from probe text, so every failure path is testable. docs/consumer-image-contract.md#how-the-gate-proves-it


_consumer_contract_row_verdict() {
  local row="$1" probe="$2" arch="$3" line
      case "${row}" in
        android-home)  line="$(_consumer_android_verdict "${row}" "${probe}")" ;;
        jdk)           line="$(_consumer_jdk_verdict "${row}" "${probe}")" ;;
        appimagetool)  line="$(_consumer_tool_verdict "${row}" "${probe}")" ;;
        flutter-owner) line="$(_consumer_owner_verdict "${row}" "${probe}")" ;;
        ort-crate-env) line="$(_consumer_ort_env_verdict "${row}" "${probe}")" ;;
        chrome|android-emulator|cargo-qa-tools|free-threaded-python|lint-tools|uv-cache-seed|gtk4-dev)
          line="$(_consumer_versioned_verdict "${row}" "${probe}" "${arch}")" ;;
        flatpak-runtimes|appimage-runtime|web-lane-tools)
                       line="$(_consumer_present_verdict "${row}" \
                                 "$(_consumer_contract_fact "${probe}" FACT "${row}")")" ;;
        *)             line="$(_consumer_dir_verdict "${row}" \
                                 "$(_consumer_contract_fact "${probe}" ENV "${row}")" \
                                 "$(_consumer_contract_fact "${probe}" WRITE "${row}")")" ;;
      esac
  printf '%s' "${line}"
}

_consumer_contract_verdicts() {
  local arch="$1" probe="$2" row fact line asserted=0
  for row in ${_CONSUMER_CONTRACT_ROWS}; do
    if _consumer_contract_exempt "${arch}" "${row}"; then
      fact="$(_consumer_exempt_fact "${row}")"
      line="$(_consumer_exempt_verdict "${row}" "${arch}" \
                "$(_consumer_contract_fact "${probe}" FACT "${fact}")" "${fact}")"
    else
      line="$(_consumer_contract_row_verdict "${row}" "${probe}" "${arch}")"
    fi
    printf '%s\n' "${line}"
    case "${line}" in OK\ *) asserted=$((asserted + 1)) ;; esac
  done
  printf 'ASSERTED %d\n' "${asserted}"
}

# Usable only if the probe completed as the image user (root sees every dir writable); EMPTY when usable.
_consumer_probe_verdict() {
  local probe="$1" want="$2" who
  if ! printf '%s\n' "${probe}" | grep -qxF -- 'CCPROBE_DONE'; then
    printf 'the probe did not complete, so the gate asserted NOTHING: %s' \
      "$(printf '%s' "${probe}" | tr '\n' ';' | head -c 300)"
  elif [ -z "${want}" ]; then
    printf '%s' "the image declares no USER, so nothing pins who a consumer runs as -- every writability answer would be root's"
  else
    who="$(printf '%s\n' "${probe}" | sed -n 's/^WHO //p' | head -1)"
    case " ${who} " in
      *" ${want} "*) ;;
      *) printf "the probe ran as '%s', not the image's own USER '%s' -- as root every directory answers writable and the gate proves nothing" "${who}" "${want}" ;;
    esac
  fi
}

# Probe as the image's own user: a root probe answers yes to every writability question.
check_consumer_contract() {
  local image_tag="$1"
  local target_arch="$2"
  local probe want stop verb row rest asserted=""
  echo "--- CONSUMER CONTRACT (${target_arch}) ---"
  want="$(_rt_image_config_value User)"
  probe="$(_rt_run_shell_probe RT_CONTRACT_SH CCPROBE_EMPTY "$(_consumer_contract_probe)" 2>/dev/null)" || true
  stop="$(_consumer_probe_verdict "${probe}" "${want}")"
  if [ -n "${stop}" ]; then
    fail "CONSUMER CONTRACT (${target_arch}): ${stop}"
    echo ""
    return 0
  fi
  while read -r verb row rest; do
    [ -n "${verb}" ] || continue
    case "${verb}" in
      OK)       echo "  OK   ${row} ${rest}" ;;
      EXEMPT)   echo "  ~~   ${row} (documented ${target_arch} exception)" ;;
      SKIP)     echo "  --   ${row} ${rest}" ;;
      BAD)      fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest} -- $(_consumer_contract_symptom "${row}")" ;;
      STALE)    fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest}" ;;
      NOFACT)   fail "CONSUMER CONTRACT ${row} (${target_arch}): ${rest} -- the probe reported no fact, so the gate could not judge the row" ;;
      ASSERTED) asserted="${row}" ;;
      *)        fail "CONSUMER CONTRACT: unknown verdict '${verb} ${row} ${rest}' -- an unhandled verb is a silently dropped row" ;;
    esac
  done < <(_consumer_contract_verdicts "${target_arch}" "${probe}")
  if [ "${asserted:-0}" = 0 ]; then
    fail "CONSUMER CONTRACT asserted NOTHING on ${target_arch} (${asserted:-no ASSERTED line}) -- an empty row table is a vacuous pass, not a compliant image"
  else
    pass "CONSUMER CONTRACT: ${asserted} row(s) hold as ${want} on ${target_arch}"
  fi
  echo ""
}
