#!/usr/bin/env bash
# Runs in the runtime-image suite's shared fixture shell.

# Consumer contract; _CC_SHIPPED is probe output measured in a shipped image, not invented
_CC_SHIPPED='WHO 1001 kataglyphis
WRITE ccache-dir no
ENV ccache-dir /workspace/.ccache
WRITE sccache-dir no
ENV sccache-dir /workspace/.sccache
WRITE rustup-tmp no
ENV rustup-tmp /usr/local/rustup/tmp
WRITE cargo-home no
ENV cargo-home /usr/local/cargo
WRITE dart-tool no
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
ENV android-home
ENV android-sdk-root
DIR android-platform-tools yes
FACT android-path no
FACT android-payload-off no
FACT flutter-sdk yes
FACT flutter-foreign 37
FACT flutter-foreign-examples /opt/flutter/.git/FETCH_HEAD /opt/flutter/.git/refs/tags
CCPROBE_DONE'

# The same image once every lane has landed.
_CC_FIXED='WHO 1001 kataglyphis
WRITE ccache-dir yes
ENV ccache-dir /var/cache/ccache
WRITE sccache-dir yes
ENV sccache-dir /var/cache/sccache
WRITE rustup-tmp yes
ENV rustup-tmp /usr/local/rustup/tmp
WRITE cargo-home yes
ENV cargo-home /usr/local/cargo
WRITE dart-tool yes
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools yes
FACT android-path yes
FACT android-payload-off no
FACT flutter-sdk yes
FACT flutter-foreign 0
FACT flutter-foreign-examples
CCPROBE_DONE'

# Rows are read from the smoke itself, so the tests never assert a stale copy.
_CC_ROWS_SRC="$(sed -n '/^_CONSUMER_CONTRACT_ROWS=/p' "${SMOKE}")"
t_assert_contains "${_CC_ROWS_SRC}" "ccache-dir" "the row list moved -- every case below reads nothing"
eval "${_CC_ROWS_SRC}"

_CC_PARTS="${_CC_ROWS_SRC}
$(_extract _consumer_contract_exempt)
$(_extract _consumer_exempt_fact)
$(_extract _consumer_contract_fact)
$(_extract _consumer_dir_verdict)
$(_extract _consumer_exempt_verdict)
$(_extract _consumer_android_verdict)
$(_extract _consumer_owner_verdict)
$(_extract _consumer_probe_verdict)
$(_extract _consumer_versioned_verdict)
$(_extract _consumer_contract_row_verdict)
$(_extract _consumer_contract_verdicts)"
# The probe exactly as check_consumer_contract sends it: the main body and both fragments it calls.
_CC_PROBE_FNS="$(_extract _consumer_contract_probe)
$(_extract _consumer_ort_env_probe)
$(_extract _consumer_test_runtimes_probe)"

# Verdict lines for one probe capture on one arch. $3 overrides the row table.
_cc_verdicts() {
  CC_PROBE="$1" CC_ROWS="${3-}" bash -c '
    '"${_CC_PARTS}"'
    [ -z "${CC_ROWS}" ] || _CONSUMER_CONTRACT_ROWS="${CC_ROWS}"
    _consumer_contract_verdicts "$1" "${CC_PROBE}"' _ "$2" 2>&1
}

t_case "the shipped image fails every row the consumer reported"
_CC_OUT="$(_cc_verdicts "${_CC_SHIPPED}" amd64)"
t_assert_contains "${_CC_OUT}" "BAD ccache-dir points into the bind-mounted checkout: /workspace/.ccache" \
  "defect 1: the cache lands in the consumer's own repository"
t_assert_contains "${_CC_OUT}" "BAD sccache-dir points into the bind-mounted checkout: /workspace/.sccache" \
  "defect 1, second half"
t_assert_contains "${_CC_OUT}" "BAD rustup-tmp not writable by the image user: /usr/local/rustup/tmp" \
  "defect 2: rustup cannot write its temp files"
t_assert_contains "${_CC_OUT}" "BAD cargo-home not writable by the image user: /usr/local/cargo" \
  "defect 2, second half"
t_assert_contains "${_CC_OUT}" "BAD android-home ANDROID_HOME=<unset>" \
  "defect 3: the SDK ships but nothing points at it"
t_assert_contains "${_CC_OUT}" "BAD dart-tool not writable by the image user" \
  "defect 4: flutter pub get cannot write package_config.json"
t_assert_contains "${_CC_OUT}" "BAD flutter-owner 37 path(s) under /opt/flutter are not owned by the runtime uid" \
  "defect 4, second half -- and the count must survive to the message"
t_assert_contains "${_CC_OUT}" "ASSERTED 0" "a wholly non-compliant image asserts nothing"

t_case "with only the ENV half of the fix, today's bytes leave exactly the two ownership rows red"
# Derived from _CC_FIXED so the two captures cannot drift; only the ownership facts differ.
_CC_ENVFIX="$(printf '%s\n' "${_CC_FIXED}" \
  | sed -e 's#^WRITE rustup-tmp yes#WRITE rustup-tmp no#' \
        -e 's#^WRITE cargo-home yes#WRITE cargo-home no#' \
        -e 's#^WRITE dart-tool yes#WRITE dart-tool no#' \
        -e 's#^FACT flutter-foreign 0#FACT flutter-foreign 37#')"
_CC_ENVFIX="$(_cc_verdicts "${_CC_ENVFIX}" amd64)"
t_assert_contains "${_CC_ENVFIX}" "OK ccache-dir /var/cache/ccache" "defect 1 needs no chown, only the bake"
t_assert_contains "${_CC_ENVFIX}" "OK sccache-dir /var/cache/sccache" "defect 1, second half"
t_assert_contains "${_CC_ENVFIX}" "OK android-home /opt/android-sdk" \
  "defect 3: both variables, the directory and both PATH entries -- exactly what Dockerfile.package appends, no more"
t_assert_contains "${_CC_ENVFIX}" "BAD rustup-tmp" "defect 2 still needs the COPY --chown to be built"
t_assert_contains "${_CC_ENVFIX}" "BAD flutter-owner 37 path(s)" "defect 4 still needs the same-RUN handover to be built"
t_assert_contains "${_CC_ENVFIX}" "ASSERTED 3" "three of the seven rows hold on today's bytes"

t_case "a cache dir inside the checkout fails even when it IS writable"
# /workspace is a writable bind mount for every consumer, so writability alone proves nothing.
t_assert_contains "$(_cc_verdicts 'WRITE ccache-dir yes
ENV ccache-dir /workspace/.ccache
CCPROBE_DONE' amd64 ccache-dir)" "BAD ccache-dir points into the bind-mounted checkout" \
  "location and writability are two separate assertions"

t_case "a dir outside the checkout that cannot be written fails"
t_assert_contains "$(_cc_verdicts 'WRITE ccache-dir no
ENV ccache-dir /var/cache/ccache
CCPROBE_DONE' amd64 ccache-dir)" "BAD ccache-dir not writable" "moving the cache out is only half the fix"

t_case "an unset directory variable fails instead of being skipped"
t_assert_contains "$(_cc_verdicts 'WRITE cargo-home no
ENV cargo-home
CCPROBE_DONE' amd64 cargo-home)" "BAD cargo-home the variable is unset" \
  "an empty value is a defect, not an absent row"

t_case "a row the probe never reported fails instead of passing"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 cargo-home)" "NOFACT cargo-home" \
  "no WRITE line means the gate could not judge the row"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 flutter-owner)" "NOFACT flutter-owner" \
  "the ownership row must not read a missing count as zero"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' amd64 android-home)" "NOFACT android-home" \
  "a missing DIR line must not read as an existing platform-tools"

# _cc_android <platform-tools dir> <on PATH> [payload-off, default no]: yes/no facts
_cc_android() {
  _cc_verdicts "ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools $1
FACT android-path $2
FACT android-payload-off ${3:-no}
CCPROBE_DONE" amd64 android-home
}

t_case "ANDROID_HOME set at a path with no platform-tools fails"
t_assert_contains "$(_cc_android no yes)" "platform-tools does not exist" \
  "an exported variable is not an SDK"

t_case "an SDK that is set and present but not on PATH still fails"
# flutter finds the SDK by variable, but sdkmanager, adb and avdmanager by PATH.
t_assert_contains "$(_cc_android yes no)" "is on PATH" "half a wiring is not the contract"

t_case "a payload-off image SKIPs the row instead of failing it"
# The NDK is linux-x86_64 only, and arm64/riscv64 prune the SDK (HOST_PAYLOAD=off): empty directories, no variables.
t_assert_contains "$(_cc_verdicts "ENV android-home
ENV android-sdk-root
DIR android-platform-tools no
FACT android-path no
FACT android-payload-off yes
CCPROBE_DONE" arm64 android-home)" "SKIP android-home" \
  "an image that RECORDED why the SDK is absent must not be judged as if it hid it"

t_case "a payload-off image that still advertises ANDROID_HOME fails"
t_assert_contains "$(_cc_android no no yes)" "says the image ships no SDK" \
  "an ANDROID_HOME over an empty /opt/android-sdk is the consumer's 'No Android SDK found' again"

t_case "a MISSING payload-off fact is NOFACT, never a silent grant"
# An absent fact is unknown, not false, so an old probe cannot restore the old verdict by omission.
t_assert_contains "$(_cc_verdicts "ENV android-home /opt/android-sdk
ENV android-sdk-root /opt/android-sdk
DIR android-platform-tools yes
FACT android-path yes
CCPROBE_DONE" amd64 android-home)" "NOFACT android-home" \
  "no FACT android-payload-off line means the gate could not judge, not that it passed"

t_case "the android row asserts exactly the two PATH entries Dockerfile.package appends"
t_assert_contains "$(_cc_android yes yes)" "OK android-home" \
  "platform-tools + cmdline-tools/latest/bin is the whole claim -- build-tools and the NDK are deliberately off PATH"

# The riscv64 /opt/flutter is empty: .dart_tool is absent (exempt) but ownership still holds.
t_case "the riscv64 flutter rows: dart-tool is exempt, flutter-owner is ASSERTED"
_CC_RV="$(_cc_verdicts 'WRITE ccache-dir yes
ENV ccache-dir /var/cache/ccache
WRITE dart-tool no
ENV dart-tool /opt/flutter/packages/flutter_tools/.dart_tool
FACT flutter-sdk no
FACT flutter-foreign 0
CCPROBE_DONE' riscv64)"
t_assert_contains "${_CC_RV}" "EXEMPT dart-tool" "upstream ships no riscv64 Flutter SDK"
t_assert_contains "${_CC_RV}" "OK flutter-owner" \
  "an empty tree owned by the runtime uid is the row PASSING, not a row to skip"
t_assert_eq 0 "$(printf '%s\n' "${_CC_RV}" | grep -c '^BAD dart-tool')" \
  "the unwritable .dart_tool of an EMPTY riscv64 tree is not a defect"

t_case "a root-owned riscv64 /opt/flutter is now a DEFECT there too"
# The dart-tool exemption must not hide root-owned paths.
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk no
FACT flutter-foreign 37
FACT flutter-foreign-examples /opt/flutter/bin
CCPROBE_DONE' riscv64 flutter-owner)" "BAD flutter-owner 37 path(s)" \
  "the ownership row must be able to go red on every arch"

t_case "the exemption fails the day a riscv64 Flutter SDK appears"
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk yes
CCPROBE_DONE' riscv64 dart-tool)" "STALE dart-tool FACT flutter-sdk says it IS present on riscv64" \
  "a table that cannot rot: the arm names itself for deletion"

t_case "each exemption is re-checked by its OWN fact, not by another row's"
# Checked against another row's fact, a riscv64 appimagetool would read EXEMPT forever.
_CC_AI="$(_cc_verdicts 'FACT flutter-sdk no
FACT appimagetool-readable yes
ENV appimagetool /usr/local/bin/appimagetool
CCPROBE_DONE' riscv64 appimagetool)"
t_assert_contains "${_CC_AI}" "STALE appimagetool FACT appimagetool-readable says it IS present on riscv64" \
  "an appimagetool that appeared on riscv64 must name its own arm for deletion"
t_assert_contains "$(_cc_verdicts 'FACT flutter-sdk no
FACT appimagetool-readable no
CCPROBE_DONE' riscv64 appimagetool)" "EXEMPT appimagetool" \
  "and the measured riscv64 shape -- packaging-deps.sh ships no riscv64 asset -- stays exempt"

t_case "every per-arch exemption's rot fact is a fact the probe really emits"
# A rot fact the probe never prints is a NOFACT on every run.
_CC_PROBE_SRC="${_CC_PROBE_FNS}"
while IFS= read -r _row; do
  [ -n "${_row}" ] || continue
  _f="$(bash -c "$(_extract _consumer_exempt_fact)"$'\n'"_consumer_exempt_fact '${_row}'")"
  t_assert_contains "${_CC_PROBE_SRC}" "FACT ${_f} " "row ${_row} is re-checked by FACT ${_f}"
done < <(_extract _consumer_contract_exempt | sed -n 's/^ *\([a-z0-9|:-]*\)) return 0 ;;/\1/p' \
           | tr '|' '\n' | sed 's/^[a-z0-9]*://')

t_case "an exemption whose rot signal is missing fails too"
t_assert_contains "$(_cc_verdicts 'CCPROBE_DONE' riscv64 dart-tool)" "NOFACT dart-tool" \
  "without FACT flutter-sdk the exemption cannot be re-checked, so it may not be granted"

t_case "the fixed image asserts every row"
_CC_OK="$(_cc_verdicts "${_CC_FIXED}" amd64)"
t_assert_contains "${_CC_OK}" "ASSERTED 7" "all seven rows must be provable at once"
t_assert_eq 0 "$(printf '%s\n' "${_CC_OK}" | grep -c '^BAD ')" "and none of them may fail"

# The gate around the verdicts: CC_USER is what the image's Config.User says.
_cc_gate() {
  CC_PROBE="$1" CC_USER="${2-kataglyphis}" CC_ROWS="${4-}" bash -c '
    '"${_STUBS}"'
    inspect_image_config() { printf "%s" "${CC_USER}"; }
    _rt_run() { printf "%s\n" "${CC_PROBE}"; }
    '"${_CC_PARTS}"'
    '"${_CC_PROBE_FNS}"'
    '"$(_extract _consumer_contract_symptom)"'
    '"$(_extract check_consumer_contract)"'
    [ -z "${CC_ROWS}" ] || _CONSUMER_CONTRACT_ROWS="${CC_ROWS}"
    check_consumer_contract img '"${3:-amd64}"'
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

t_case "the probe is one program and reports every verb the verdicts read"
# Run on the host: the probe's shell is the code under test, not the image.
_CC_TMP="$(mktemp -d)"
# The fixture, not the probe, creates the dirs: a missing dir is one the consumer's `[ -w ]` calls false.
mkdir -p "${_CC_TMP}"/{cc,sc,ru/tmp,ca,sdk/platform-tools,ort}
: > "${_CC_TMP}/ort/libonnxruntime.so"
_CC_RAW="$(CCACHE_DIR="${_CC_TMP}/cc" SCCACHE_DIR="${_CC_TMP}/sc" RUSTUP_HOME="${_CC_TMP}/ru" \
  CARGO_HOME="${_CC_TMP}/ca" ANDROID_HOME="${_CC_TMP}/sdk" ANDROID_SDK_ROOT="${_CC_TMP}/sdk" \
  ORT_LIB_LOCATION="${_CC_TMP}/ort" ORT_DYLIB_PATH="${_CC_TMP}/ort/libonnxruntime.so" ORT_SKIP_DOWNLOAD=1 CARGO_NET_OFFLINE='' \
  env -u ORT_LIB_PATH bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)"
t_assert_contains "${_CC_RAW}" "CCPROBE_DONE" "exit status is not evidence; the sentinel is"
t_assert_contains "${_CC_RAW}" "WHO " "the gate refuses to judge a probe that did not say who it ran as"
for _r in ccache-dir sccache-dir rustup-tmp cargo-home dart-tool; do
  t_assert_contains "${_CC_RAW}" "WRITE ${_r} " "the probe must report writability for ${_r}"
  t_assert_contains "${_CC_RAW}" "ENV ${_r} " "the probe must report the resolved path for ${_r}"
done
t_assert_contains "${_CC_RAW}" "DIR android-platform-tools " "the android row reads a directory, not a variable"
t_assert_contains "${_CC_RAW}" "FACT android-path " "the android row also reads PATH, where adb and sdkmanager are found"
t_assert_contains "${_CC_RAW}" "FACT flutter-sdk " "the exemption rot signal must be emitted"
t_assert_contains "${_CC_RAW}" "FACT flutter-foreign " "the ownership count must be emitted"
# G3: the ort crate env as set, where it resolves, the linker name, and the completion fact.
for _f in "ENV ort-lib-location ${_CC_TMP}/ort" "FACT ort-lib-real $(readlink -e -- "${_CC_TMP}/ort")" \
          "FACT ort-link-lib yes" "ENV ort-skip-download 1" "ENV ort-lib-path <unset>" "FACT ort-probe yes"; do
  t_assert_contains "${_CC_RAW}" "${_f}" "the ort-crate-env row reads it"
done
t_assert_eq 1 "$(printf '%s\n' "${_CC_RAW}" | grep -cx -e 'ENV cargo-net-offline ' || true)" "set-but-empty is set: ort-sys reads it"

t_case "the probe answers YES only where it really wrote"
t_assert_contains "${_CC_RAW}" "WRITE ccache-dir yes" "a writable directory must read as writable"
t_assert_eq "" "$(ls -A "${_CC_TMP}/cc")" "and the probe must leave nothing behind in it"
: > "${_CC_TMP}/notadir"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/notadir/x" bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  "WRITE cargo-home no" "a path the probe cannot create a file in must read as unwritable, for root too"
t_assert_contains "$(CARGO_HOME="${_CC_TMP}/absent" bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  "WRITE cargo-home no" "a MISSING directory is what the consumer's [ -w ] calls false; a probe that creates it reports green where they fail"
rm -rf "${_CC_TMP}"

t_case "a red row names the symptom the consuming repo actually saw"
_CC_G="$(_cc_gate "${_CC_SHIPPED}")"
t_assert_contains "${_CC_G}" "Permission denied (os error 13)" "the rustup row must quote what the consumer's log says"
t_assert_contains "${_CC_G}" "No Android SDK found" "the android row must name the flutter failure, not our path"
t_assert_contains "${_CC_G}" "package_config.json" "the .dart_tool row must name pub get"
t_assert_contains "${_CC_G}" "tmpfs" "the ownership row must say why a consumer cannot fix it themselves"

t_case "a probe that never ran fails instead of passing empty"
t_assert_contains "$(_cc_gate "bash: line 1: id: command not found")" "asserted NOTHING" \
  "no CCPROBE_DONE marker means the gate proved nothing"

t_case "a probe that ran as root proves nothing and fails"
# Every directory is writable to uid 0.
t_assert_contains "$(_cc_gate "$(printf '%s\n' "${_CC_FIXED}" | sed 's/^WHO .*/WHO 0 root/')")" \
  "not the image's own USER" "a root probe is not a consumer"

t_case "an image that declares no USER fails"
t_assert_contains "$(_cc_gate "${_CC_FIXED}" "")" "declares no USER" \
  "nothing pins who a consumer runs as"

t_case "an emptied row table is a vacuous pass, not a green image"
t_assert_contains "$(_cc_gate "${_CC_FIXED}" kataglyphis amd64 " ")" "asserted NOTHING" \
  "the gate reduces to its table, so an empty table must fail rather than print PASS all 0"

t_case "a verdict verb no arm handles fails instead of being dropped"
t_assert_contains "$(_cc_gate "${_CC_FIXED}")" "" "gate ran"
_CC_UNK="$(CC_V="WHAT ccache-dir x" bash -c '
    '"${_STUBS}"'
    _consumer_contract_verdicts() { printf "%s\nASSERTED 1\n" "${CC_V}"; }
    inspect_image_config() { printf "kataglyphis"; }
    _rt_run() { printf "WHO 1001 kataglyphis\nCCPROBE_DONE\n"; }
    '"$(_extract _consumer_contract_symptom)"'
    '"$(_extract check_consumer_contract)"'
    check_consumer_contract img amd64' 2>&1)"
t_assert_contains "${_CC_UNK}" "unknown verdict" "an unhandled verb is a silently dropped row"

t_case "the compliant image passes the gate"
_CC_PASS="$(_cc_gate "${_CC_FIXED}")"
t_assert_contains "${_CC_PASS}" "PASS CONSUMER CONTRACT: 7 row(s) hold as kataglyphis" "what a fixed image prints"
t_assert_contains "${_CC_PASS}" "FAILURES=0" "and nothing else may go red"

t_case "the appimagetool row: executable is not the same as usable"
_toolv() { bash -c '
    '"$(_extract _consumer_contract_fact)"'
    '"$(_extract _consumer_tool_verdict)"'
    _consumer_tool_verdict appimagetool "$1"' _ "$1" 2>&1; }
t_assert_contains "$(_toolv "ENV appimagetool /usr/local/bin/appimagetool
FACT appimagetool-readable no")" "is not readable by the image user" \
  "mode 711 runs for root and fails for uid 1001, which is who ships"
t_assert_contains "$(_toolv "ENV appimagetool
FACT appimagetool-readable no")" "not on PATH at all" "an absent tool is a different failure than an unreadable one"
t_assert_contains "$(_toolv "ENV appimagetool /usr/local/bin/appimagetool
FACT appimagetool-readable yes")" "OK appimagetool" "the fixed shape"
t_assert_contains "$(_toolv "ENV appimagetool /x")" "NOFACT appimagetool" "a probe with no readability fact proves nothing"

t_case "the JDK row: Gradle reads JAVA_HOME, so java on PATH alone is not enough"
_jdkv() { bash -c '
    '"$(_extract _consumer_contract_fact)"'
    '"$(_extract _consumer_jdk_verdict)"'
    _consumer_jdk_verdict jdk "$1"' _ "$1" 2>&1; }
t_assert_contains "$(_jdkv "FACT java-on-path no
FACT javac no")" "BAD jdk no java on PATH" "the shipped image today: the SDK without its JDK"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac yes
ENV java-home ")" "JAVA_HOME is unset" "Gradle reads the variable, not the PATH entry"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac no
ENV java-home /usr/lib/jvm/default-java")" "has no bin/javac" "a JRE cannot compile"
t_assert_contains "$(_jdkv "FACT java-on-path yes
FACT javac yes
ENV java-home /usr/lib/jvm/default-java")" "OK jdk" "the fixed shape"
t_assert_contains "$(_jdkv "ENV java-home /x")" "NOFACT jdk" "a probe that emitted no java facts proves nothing"

# CON50's browser and emulator rows; the pins come from the env, which _rt_versions_env_pin reads first.
_CC_TR_PARTS="${_CC_PARTS}
$(_extract _rt_env_pin)
$(_extract _rt_versions_env_pin)
$(_extract _consumer_require_fact)
$(_extract _consumer_version_matches)
$(_extract _consumer_chrome_verdict)
$(_extract _consumer_emulator_verdict)
$(_extract _consumer_cargo_qa_verdict)
$(_extract _consumer_free_threaded_verdict)"
# _cc_tr <probe> <arch> <row>
_cc_tr() {
  CC_PROBE="$1" CHROME_FOR_TESTING_VERSION=154.0.8037.92 ANDROID_EMULATOR_VERSION=37.2.12 ANDROID_EMULATOR_API=35 \
    ANDROID_EMULATOR_SYSIMG_REVISION=9 CARGO_AUDIT_VERSION=0.22.2 CARGO_DENY_VERSION=0.20.2 CARGO_TARPAULIN_VERSION=0.37.2 PYTHON_VERSION=3.14.7 bash -c '
    '"${_CC_TR_PARTS}"'
    _CONSUMER_CONTRACT_ROWS="$2"
    _consumer_contract_verdicts "$1" "${CC_PROBE}"' _ "$2" "$3" 2>&1
}
_CC_CHROME='ENV chrome-executable /usr/local/bin/chrome
FACT chrome yes
FACT chrome-version 154.0.8037.92
FACT chromedriver-version 154.0.8037.92
FACT chrome-headless yes'
_CC_EMU='FACT android-payload-off no
FACT android-emulator yes
FACT android-emulator-version 37.2.12
FACT android-emulator-runs yes
FACT android-system-image android-35;google_apis;x86_64;r9
FACT android-avd yes'
_cc_edit() { printf '%s\n' "$1" | sed -e "$2"; }

t_case "CON50: the pinned browser rendering headless holds the chrome row on amd64 and arm64"
for _a in amd64 arm64; do
  t_assert_contains "$(_cc_tr "${_CC_CHROME}" "${_a}" chrome)" "OK chrome Chrome for Testing 154.0.8037.92 renders headless" "${_a}"
done

t_case "CON50: a browser that renders nothing, runs off the pin or lacks its chromedriver is BAD (mutation)"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" 's/^FACT chrome-headless yes/FACT chrome-headless no/')" amd64 chrome)" \
  "BAD chrome headless chrome rendered no page"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" 's/^FACT chrome-version .*/FACT chrome-version 153.0.1.1/')" amd64 chrome)" \
  "BAD chrome chrome reports 153.0.1.1, the pin is 154.0.8037.92"
t_assert_contains "$(_cc_tr "$(_cc_edit "${_CC_CHROME}" '/^FACT chromedriver-version/d')" amd64 chrome)" \
  "BAD chrome chromedriver reports nothing"
t_assert_contains "$(_cc_tr 'ENV chrome-executable
FACT chrome no' arm64 chrome)" "BAD chrome CHROME_EXECUTABLE () names no executable browser" "an arm64 image without its browser"
t_assert_contains "$(_cc_tr 'ENV chrome-executable /x' amd64 chrome)" "NOFACT chrome" "a probe that never answered proves nothing"

t_case "CON50: riscv64 is exempt from the chrome row, and the arm rots the day a browser appears"
t_assert_contains "$(_cc_tr 'FACT chrome no' riscv64 chrome)" "EXEMPT chrome"
t_assert_contains "$(_cc_tr "${_CC_CHROME}" riscv64 chrome)" "STALE chrome FACT chrome says it IS present on riscv64"

t_case "CON50: the pinned emulator, system image and AVD helper hold the row on amd64"
t_assert_contains "$(_cc_tr "${_CC_EMU}" amd64 android-emulator)" \
  "OK android-emulator emulator 37.2.12 with android-35;google_apis;x86_64;r9"

t_case "CON50: every broken part of the emulator payload is BAD (mutation)"
_emu_bad() { _cc_tr "$(_cc_edit "${_CC_EMU}" "$1")" amd64 android-emulator; }
_t_edit_table _emu_bad <<'ROWS'
s/^FACT android-emulator yes/FACT android-emulator no/	BAD android-emulator ANDROID_HOME/emulator/emulator is missing
s/^FACT android-emulator-runs yes/FACT android-emulator-runs no/	BAD android-emulator the emulator does not run as the image user
s/^FACT android-emulator-version .*/FACT android-emulator-version 37.2.11/	BAD android-emulator emulator 37.2.11, the pin is 37.2.12
s/;r9$/;r8/	BAD android-emulator system image android-35;google_apis;x86_64;r8, the pin is android-35;google_apis;x86_64;r9
/^FACT android-system-image/d	BAD android-emulator system image none
s/^FACT android-avd yes/FACT android-avd no/	BAD android-emulator android-avd.sh is not on PATH
s/^FACT android-payload-off no/FACT android-payload-off yes/	SKIP android-emulator
/^FACT android-payload-off/d	NOFACT android-emulator no FACT android-payload-off line
ROWS

t_case "CON50: arm64 and riscv64 are exempt from the emulator row, each re-checked by the emulator's own fact"
for _a in arm64 riscv64; do
  t_assert_contains "$(_cc_tr 'FACT android-emulator no' "${_a}" android-emulator)" "EXEMPT android-emulator" "${_a}"
  t_assert_contains "$(_cc_tr "${_CC_EMU}" "${_a}" android-emulator)" "STALE android-emulator FACT android-emulator says it IS present on ${_a}"
done

_CC_QA='FACT cargo-qa-tools yes
FACT cargo-qa-tools-versions cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2'

t_case "CON65: the three cargo QA tools at their pins hold the row on amd64 and arm64"
for _a in amd64 arm64; do
  t_assert_contains "$(_cc_tr "${_CC_QA}" "${_a}" cargo-qa-tools)" \
    "OK cargo-qa-tools cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2" "${_a}"
done

t_case "CON65: a tool off its pin or missing is BAD, and no fact proves nothing (mutation)"
_qa_bad() { _cc_tr "$(_cc_edit "${_CC_QA}" "$1")" arm64 cargo-qa-tools; }
_t_edit_table _qa_bad <<'ROWS'
s/cargo-deny=0.20.2/cargo-deny=0.19.0/	BAD cargo-qa-tools the image has cargo-audit=0.22.2 cargo-deny=0.19.0
s/cargo-tarpaulin=0.37.2/cargo-tarpaulin=/	BAD cargo-qa-tools the image has cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=
/^FACT cargo-qa-tools /d	NOFACT cargo-qa-tools no FACT cargo-qa-tools line
ROWS

t_case "CON65: riscv64 is exempt from the cargo QA row, and the arm rots the day one appears"
t_assert_contains "$(_cc_tr 'FACT cargo-qa-tools no' riscv64 cargo-qa-tools)" "EXEMPT cargo-qa-tools"
t_assert_contains "$(_cc_tr "${_CC_QA}" riscv64 cargo-qa-tools)" "STALE cargo-qa-tools FACT cargo-qa-tools says it IS present on riscv64"

_FT_SRC='FACT free-threaded-python-build prefix=/opt/python-freethreaded Py_GIL_DISABLED=1'
t_case "CON66: the toolchain's free-threaded source build at PYTHON_VERSION holds the row on every arch"
for _a in amd64 arm64 riscv64; do
  t_assert_contains "$(_cc_tr "FACT free-threaded-python 3.14.7 gil=False
${_FT_SRC}" "${_a}" free-threaded-python)" \
    "OK free-threaded-python CPython 3.14.7 without the GIL, built from source in /opt/python-freethreaded" "${_a}"
done

t_case "CON66: a GIL build, another patch or no interpreter is BAD, and no fact proves nothing (mutation)"
_ft_bad() { _cc_tr "FACT free-threaded-python $1
${_FT_SRC}" amd64 free-threaded-python; }
t_assert_contains "$(_ft_bad '3.14.7 gil=True')" "BAD free-threaded-python python3.*t reports 3.14.7 gil=True"
t_assert_contains "$(_ft_bad '3.14.4 gil=False')" "BAD free-threaded-python python3.*t reports 3.14.4 gil=False"
t_assert_contains "$(_ft_bad 'none')" "BAD free-threaded-python python3.*t reports none"
t_assert_contains "$(_cc_tr 'FACT other yes' amd64 free-threaded-python)" "NOFACT free-threaded-python"

t_case "CON66: uv's python-build-standalone tree, a missing stdlib module or no build fact is BAD (mutation)"
_ft_src_bad() { _cc_tr "FACT free-threaded-python 3.14.7 gil=False${1:+
FACT free-threaded-python-build $1}" amd64 free-threaded-python; }
t_assert_contains "$(_ft_src_bad 'prefix=/opt/python-freethreaded/cpython-3.14.7+freethreaded-linux-x86_64-gnu Py_GIL_DISABLED=1')" \
  "BAD free-threaded-python python3.*t is not the source build in /opt/python-freethreaded with its stdlib: prefix=/opt/python-freethreaded/cpython-3.14.7"
t_assert_contains "$(_ft_src_bad "ModuleNotFoundError: No module named '_ctypes'")" \
  "with its stdlib: ModuleNotFoundError: No module named '_ctypes'"
t_assert_contains "$(_ft_src_bad '')" "with its stdlib: no FACT free-threaded-python-build line"

t_case "CON50: the probe emits every fact the two rows read, as a real run of it"
_TR_TMP="$(mktemp -d)"
mkdir -p "${_TR_TMP}/bin" "${_TR_TMP}/sdk/emulator" "${_TR_TMP}/sdk/system-images/android-35/google_apis/x86_64"
printf '#!/bin/sh\ncase "$*" in *--version*) echo "Google Chrome for Testing 154.0.8037.92 " ;; *--dump-dom*) echo "<body>kg-42</body>" ;; esac\n' \
  > "${_TR_TMP}/bin/chrome"
printf '#!/bin/sh\necho "ChromeDriver 154.0.8037.92 (x)"\n' > "${_TR_TMP}/bin/chromedriver"
printf '#!/bin/sh\necho "cargo-audit 0.22.2"\n' > "${_TR_TMP}/bin/cargo-audit"
printf '#!/bin/sh\necho "cargo-deny 0.20.2"\n' > "${_TR_TMP}/bin/cargo-deny"
printf '#!/bin/sh\necho "tarpaulin 0.37.2"\n' > "${_TR_TMP}/bin/cargo-tarpaulin"
printf '#!/bin/sh\ncase "$2" in *sysconfig*) echo "prefix=/opt/python-freethreaded Py_GIL_DISABLED=1" ;; *) echo "3.14.7 gil=False" ;; esac\n' \
  > "${_TR_TMP}/bin/python3.14t"
printf '#!/bin/sh\necho "Android emulator version 37.2.12.0 (build_id 16428233)"\n' > "${_TR_TMP}/sdk/emulator/emulator"
: > "${_TR_TMP}/bin/android-avd.sh"
chmod +x "${_TR_TMP}"/bin/* "${_TR_TMP}/sdk/emulator/emulator"
printf 'Pkg.Revision=37.2.12\n' > "${_TR_TMP}/sdk/emulator/source.properties"
printf 'Pkg.Revision=9\nAndroidVersion.ApiLevel=35\nSystemImage.TagId=google_apis\nSystemImage.Abi=x86_64\n' \
  > "${_TR_TMP}/sdk/system-images/android-35/google_apis/x86_64/source.properties"
_TR_RAW="$(PATH="${_TR_TMP}/bin:${PATH}" CHROME_EXECUTABLE="${_TR_TMP}/bin/chrome" ANDROID_HOME="${_TR_TMP}/sdk" \
  bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)"
for _f in "FACT chrome yes" "FACT chrome-version 154.0.8037.92" "FACT chromedriver-version 154.0.8037.92" \
          "FACT chrome-headless yes" "FACT android-emulator yes" "FACT android-emulator-version 37.2.12" \
          "FACT android-emulator-runs yes" "FACT android-system-image android-35;google_apis;x86_64;r9" "FACT android-avd yes" \
          "FACT cargo-qa-tools yes" "FACT cargo-qa-tools-versions cargo-audit=0.22.2 cargo-deny=0.20.2 cargo-tarpaulin=0.37.2" \
          "FACT free-threaded-python 3.14.7 gil=False" "${_FT_SRC}"; do
  t_assert_contains "${_TR_RAW}" "${_f}" "the probe reads it from the image"
done
t_assert_contains "$(CHROME_EXECUTABLE='' ANDROID_HOME="${_TR_TMP}/none" \
  bash -c "${_CC_PROBE_FNS}"$'\n'"_consumer_contract_probe | bash" 2>&1)" \
  $'FACT chrome no' "an empty CHROME_EXECUTABLE is riscv64's shape"
rm -rf "${_TR_TMP}"


t_case "unknown and empty symptom rows retain the fallback diagnostic"
for _row in unknown ""; do
  t_assert_eq "no symptom recorded for this row" "$(bash -c 'source "$1"; _consumer_contract_symptom "$2"' _ "${SMOKE%/*}/runtime-consumer-contract.sh" "${_row}")"
done
