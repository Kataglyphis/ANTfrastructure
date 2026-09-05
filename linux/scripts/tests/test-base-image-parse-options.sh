#!/usr/bin/env bash
# Pins the per-command asymmetries of 01-core/base-image.sh parse_options that a
# "harmonizing" rewrite would eat.
# docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

BASE_IMAGE_SH="${TESTS_DIR}/../01-core/base-image.sh"

# ---------------------------------------------------------------------------
# Mode 1: run base-image.sh for real and report "<rc>|<stderr>".
# ---------------------------------------------------------------------------
bi_run() {
  local out rc=0
  out="$(NO_COLOR=1 bash "${BASE_IMAGE_SH}" "$@" 2>&1 >/dev/null)" || rc=$?
  printf '%s|%s' "${rc}" "${out}"
}

bi_rc()  { printf '%s' "${1%%|*}"; }
bi_msg() { printf '%s' "${1#*|}"; }

t_case "install-node: a flag with no value dies with the shared missing-value message"
_r="$(bi_run install-node --version)"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_contains "$(bi_msg "${_r}")" "Missing value for --version"

t_case "install-shared-build-tooling: empty --cmake-version is rejected"
_r="$(bi_run install-shared-build-tooling --cmake-version "")"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_contains "$(bi_msg "${_r}")" "Missing value for --cmake-version"

t_case "init-compiler-caches: empty --max-size is rejected"
t_assert_contains "$(bi_msg "$(bi_run init-compiler-caches --max-size "")")" \
  "Missing value for --max-size"

t_case "install-uv: empty --version is rejected"
t_assert_contains "$(bi_msg "$(bi_run install-uv --version "")")" \
  "Missing value for --version"

t_case "configure-fast-mirror: EMPTY --archive-url is rejected (asymmetry vs --ports-url)"
_r="$(bi_run configure-fast-mirror --archive-url "")"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_contains "$(bi_msg "${_r}")" "Missing value for --archive-url"

t_case "configure-fast-mirror: --rewrite-security validates its boolean"
_r="$(bi_run configure-fast-mirror --rewrite-security maybe)"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_contains "$(bi_msg "${_r}")" "Invalid boolean for --rewrite-security: maybe"
t_assert_contains "$(bi_msg "$(bi_run configure-fast-mirror --rewrite-security "")")" \
  "Missing value for --rewrite-security"

t_case "unknown flags die with the per-command message, verbatim"
t_assert_contains "$(bi_msg "$(bi_run install-node --bogus x)")" \
  "Unknown argument for install-node: --bogus"
t_assert_contains "$(bi_msg "$(bi_run install-node --cmake-version 4.4.2)")" \
  "Unknown argument for install-node: --cmake-version"
t_assert_contains "$(bi_msg "$(bi_run configure-fast-mirror --max-size 1)")" \
  "Unknown argument for configure-fast-mirror: --max-size"
t_assert_contains "$(bi_msg "$(bi_run install-vulkan-runtime-files --bogus)")" \
  "Unknown argument for install-vulkan-runtime-files: --bogus"

t_case "a bare positional is an unknown ARGUMENT for the flags-only commands"
t_assert_contains "$(bi_msg "$(bi_run install-uv somedir)")" \
  "Unknown argument for install-uv: somedir"

t_case "no-argument commands reject extras with their own message"
for _cmd in bootstrap-ca restore-mirror-scheme install-os-packages; do
  _r="$(bi_run "${_cmd}" extra)"
  t_assert_eq "1" "$(bi_rc "${_r}")"
  t_assert_eq "[ERROR] ${_cmd} does not accept extra arguments" "$(bi_msg "${_r}")"
done
t_assert_contains "$(bi_msg "$(bi_run bootstrap-ca --version 1)")" \
  "bootstrap-ca does not accept extra arguments"

t_case "an unknown command WITH arguments reports command and arguments"
_r="$(bi_run bogus-command foo bar)"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_eq "[ERROR] Unknown command or arguments: bogus-command foo bar" "$(bi_msg "${_r}")"

t_case "an unknown command WITHOUT arguments falls through to usage, rc 1"
_r="$(bi_run bogus-command)"
t_assert_eq "1" "$(bi_rc "${_r}")"
t_assert_contains "$(bi_msg "${_r}")" "Usage: base-image.sh <command> [options]"

t_case "--help prints usage and succeeds"
t_assert_ok bash "${BASE_IMAGE_SH}" --help

# ---------------------------------------------------------------------------
# Mode 2: source ONLY the parser region with a stub die(), so a parse can be
# asserted on the variables it assigns. Each case runs in a FRESH bash PROCESS,
# not a subshell — see docs/cross-build-verification.md
# ---------------------------------------------------------------------------
BI_TMP="$(mktemp -d)"
trap 'rm -rf "${BI_TMP}"' EXIT
awk '/^require_single_value\(\) \{$/{f=1} /^base_image_arch\(\) \{$/{f=0} f' \
  "${BASE_IMAGE_SH}" > "${BI_TMP}/parse-region.sh"

cat > "${BI_TMP}/drive-parse.sh" <<'DRIVER'
#!/usr/bin/env bash
# Drives parse_options with base-image.sh's own shell options and prints the
# outcome: "var:<NAME>" -> that variable's value (or <unset>);
# "remaining" -> "<count>:<arg>|<arg>|...".
set -euo pipefail
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
# shellcheck source=/dev/null
source "${BI_PARSE_REGION}"
REMAINING_ARGS=()
mode="$1"; shift
parse_options "$@"
case "${mode}" in
  var:*)
    _name="${mode#var:}"
    printf '%s' "${!_name-<unset>}"
    ;;
  remaining)
    printf '%s:' "${#REMAINING_ARGS[@]}"
    for _a in ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}; do printf '%s|' "${_a}"; done
    ;;
esac
DRIVER
export BI_PARSE_REGION="${BI_TMP}/parse-region.sh"

# bi_parse <mode> <parse_options args...> — see drive-parse.sh above.
bi_parse() { bash "${BI_TMP}/drive-parse.sh" "$@"; }
bi_var() { local v="$1"; shift; bi_parse "var:${v}" "$@"; }
bi_remaining() { bi_parse remaining "$@"; }

t_case "the parser region extracted cleanly"
t_assert_ok bi_parse remaining bootstrap-ca
t_assert_contains "$(grep -c 'parse_options() {' "${BI_TMP}/parse-region.sh")" "1"

t_case "every command assigns its own target variable"
t_assert_eq "4.5.1" "$(bi_var BASE_IMAGE_CMAKE_VERSION install-shared-build-tooling --cmake-version 4.5.1)"
t_assert_eq "24.9.0" "$(bi_var BASE_IMAGE_NODE_VERSION install-node --version 24.9.0)"
t_assert_eq "0.9.7" "$(bi_var BASE_IMAGE_UV_VERSION install-uv --version 0.9.7)"
t_assert_eq "40G" "$(bi_var BASE_IMAGE_CCACHE_MAXSIZE init-compiler-caches --max-size 40G)"
t_assert_eq "1.4.321" "$(bi_var BASE_IMAGE_VULKAN_VERSION install-vulkan-runtime-files --version 1.4.321)"
t_assert_eq "http://mirror.test/ubuntu/" \
  "$(bi_var FAST_UBUNTU_MIRROR_URL configure-fast-mirror --archive-url http://mirror.test/ubuntu/)"
t_assert_eq "http://mirror.test/ports/" \
  "$(bi_var FAST_UBUNTU_PORTS_MIRROR_URL configure-fast-mirror --ports-url http://mirror.test/ports/)"

t_case "a repeated flag keeps the LAST value"
t_assert_eq "second" "$(bi_var BASE_IMAGE_NODE_VERSION install-node --version first --version second)"

t_case "no flags at all leaves the target untouched"
t_assert_eq "<unset>" "$(bi_var BASE_IMAGE_CMAKE_VERSION install-shared-build-tooling)"

t_case "both mirror URL flags also opt INTO the fast mirror"
t_assert_eq "true" "$(bi_var USE_FAST_UBUNTU_MIRROR configure-fast-mirror --archive-url http://m/u/)"
t_assert_eq "true" "$(bi_var USE_FAST_UBUNTU_MIRROR configure-fast-mirror --ports-url http://m/p/)"
t_assert_eq "true" "$(bi_var USE_FAST_UBUNTU_MIRROR configure-fast-mirror --ports-url "")"

t_case "--rewrite-security does NOT opt into the fast mirror"
t_assert_eq "<unset>" "$(bi_var USE_FAST_UBUNTU_MIRROR configure-fast-mirror --rewrite-security true)"

t_case "an EMPTY --ports-url is legal and assigned verbatim (the asymmetry)"
t_assert_eq "" "$(bi_var FAST_UBUNTU_PORTS_MIRROR_URL configure-fast-mirror --ports-url "" --archive-url http://a/)"
t_assert_eq "http://a/" \
  "$(bi_var FAST_UBUNTU_MIRROR_URL configure-fast-mirror --ports-url "" --archive-url http://a/)"

t_case "a trailing flag with NO value at all still fails (the shift-2 guard)"
# `--ports-url` last: the empty value is legal, but `shift 2` then runs out.
t_assert_fails bi_var FAST_UBUNTU_PORTS_MIRROR_URL configure-fast-mirror --ports-url
t_assert_ok bi_var FAST_UBUNTU_PORTS_MIRROR_URL configure-fast-mirror --ports-url ""

t_case "parse_bool_flag accepts every documented spelling, verbatim"
for _b in 1 true TRUE yes YES 0 false FALSE no NO; do
  t_assert_eq "${_b}" "$(bi_var FAST_UBUNTU_REWRITE_SECURITY configure-fast-mirror --rewrite-security "${_b}")"
done

t_case "parse_bool_flag rejects non-booleans"
t_assert_fails bi_var FAST_UBUNTU_REWRITE_SECURITY configure-fast-mirror --rewrite-security True
t_assert_fails bi_var FAST_UBUNTU_REWRITE_SECURITY configure-fast-mirror --rewrite-security 2
t_assert_fails bi_var FAST_UBUNTU_REWRITE_SECURITY configure-fast-mirror --rewrite-security "no thanks"

t_case "all three configure-fast-mirror flags parse together"
t_assert_eq "http://a/" "$(bi_var FAST_UBUNTU_MIRROR_URL configure-fast-mirror --archive-url http://a/ --ports-url http://p/ --rewrite-security yes)"
t_assert_eq "http://p/" "$(bi_var FAST_UBUNTU_PORTS_MIRROR_URL configure-fast-mirror --archive-url http://a/ --ports-url http://p/ --rewrite-security yes)"
t_assert_eq "yes" "$(bi_var FAST_UBUNTU_REWRITE_SECURITY configure-fast-mirror --archive-url http://a/ --ports-url http://p/ --rewrite-security yes)"

t_case "install-vulkan-runtime-files passes the trailing positionals through"
t_assert_eq "0:" "$(bi_remaining install-vulkan-runtime-files)"
t_assert_eq "0:" "$(bi_remaining install-vulkan-runtime-files --version 1.4.0)"
t_assert_eq "1:/tmp/vulkan|" "$(bi_remaining install-vulkan-runtime-files --version 1.4.0 /tmp/vulkan)"
t_assert_eq "1:/tmp/vulkan|" "$(bi_remaining install-vulkan-runtime-files /tmp/vulkan)"
t_assert_eq "3:a|b|c|" "$(bi_remaining install-vulkan-runtime-files --version 1.4.0 a b c)"

t_case "install-vulkan-runtime-files stops at a bare non-flag WITHOUT parsing the rest"
# The first non-flag ends option parsing: a later flag is a positional.
t_assert_eq "2:/tmp/vulkan|--version|" "$(bi_remaining install-vulkan-runtime-files /tmp/vulkan --version)"
t_assert_eq "<unset>" "$(bi_var BASE_IMAGE_VULKAN_VERSION install-vulkan-runtime-files /tmp/vulkan --version 1.4.0)"

t_case "install-vulkan-runtime-files honors an explicit -- terminator"
t_assert_eq "1:/tmp/vulkan|" "$(bi_remaining install-vulkan-runtime-files -- /tmp/vulkan)"
t_assert_eq "0:" "$(bi_remaining install-vulkan-runtime-files --)"
t_assert_eq "1:--version|" "$(bi_remaining install-vulkan-runtime-files -- --version)"
t_assert_eq "1:--weird|" "$(bi_remaining install-vulkan-runtime-files --version 1.4.0 -- --weird)"
t_assert_eq "1.4.0" "$(bi_var BASE_IMAGE_VULKAN_VERSION install-vulkan-runtime-files --version 1.4.0 -- --weird)"

t_case "install-vulkan-runtime-files still rejects an unknown dash-flag"
t_assert_fails bi_remaining install-vulkan-runtime-files -x
t_assert_fails bi_remaining install-vulkan-runtime-files -
t_assert_fails bi_remaining install-vulkan-runtime-files --version

t_case "REMAINING_ARGS is set by install-vulkan-runtime-files ONLY"
# Every other command leaves the array main() pre-seeded as it found it.
t_assert_eq "0:" "$(bi_remaining install-node --version 24.9.0)"
t_assert_eq "0:" "$(bi_remaining bootstrap-ca)"
t_assert_eq "0:" "$(bi_remaining configure-fast-mirror --archive-url http://a/)"

t_case "the no-argument and catch-all arms accept nothing but zero arguments"
t_assert_ok bi_remaining restore-mirror-scheme
t_assert_ok bi_remaining install-os-packages
t_assert_ok bi_remaining bogus-command
t_assert_fails bi_remaining bogus-command extra

t_summary
