#!/usr/bin/env bash
# security-audit.sh replaying recorded osv-scanner JSON offline; not covered: the live OSV query, reachability, container images.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
AUDIT="${TESTS_DIR}/../security-audit.sh"
FIXTURES="${TESTS_DIR}/fixtures/security-audit"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
export HOME="${_work}/home" CARGO_SAFE_DIRECTORY=""
mkdir -p "${HOME}" "${_work}/bin"

# The fake scanner records its arguments and replays one fixture with @ROOT@ set to the scanned tree.
cat > "${_work}/bin/osv-scanner" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'osv-scanner version: 2.7.0'; exit 0; fi
printf '%s\n' "$@" > "${FAKE_OSV_ARGS}"
out=""
while [ "$#" -gt 0 ]; do [ "$1" = --output-file ] && out="$2"; shift; done
sed "s|@ROOT@|${FAKE_OSV_ROOT}|g" "${FAKE_OSV_FIXTURE}" > "${out}"
exit 1
EOF
printf '#!/bin/sh\necho "$PWD cargo $*" >> "%s/cargo.log"\n' "${_work}" > "${_work}/bin/cargo"
chmod +x "${_work}/bin/osv-scanner" "${_work}/bin/cargo"
export SECURITY_AUDIT_OSV_SCANNER="${_work}/bin/osv-scanner" FAKE_OSV_ARGS="${_work}/args"
export PATH="${_work}/bin:${PATH}"

_UV_BASE='version = 1
requires-python = ">=3.12"

[[package]]
name = "pyyaml"
version = "6.0.3"
source = { registry = "https://pypi.org/simple" }'
_UV_HYDRA="${_UV_BASE}

[[package]]
name = \"hydra-core\"
version = \"1.3.7\"
source = { registry = \"https://pypi.org/simple\" }"

# _repo <uv.lock body>: one commit holding that uv.lock; prints the tree.
_repo() {
  local d; d="$(mktemp -d "${_work}/repo.XXXXXX")"
  git -C "${d}" init -q
  printf '%s\n' "$1" > "${d}/uv.lock"
  t_git_commit "${d}"
  printf '%s' "${d}"
}

# _audit <tree> <fixture> <args...>: runs the audit there; the JSON lands in <tree>/security-audit.json.
_audit() {
  local tree="$1" fixture="$2"
  shift 2
  case "${fixture}" in /*) ;; *) fixture="${FIXTURES}/${fixture}" ;; esac
  ( cd "${tree}" && FAKE_OSV_ROOT="${tree}" FAKE_OSV_FIXTURE="${fixture}" bash "${AUDIT}" "$@" )
}

_json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1/security-audit.json" "$2"; }

t_case "a commit that adds hydra-core 1.3.7 to a uv.lock FAILS push mode"
added="$(_repo "${_UV_BASE}")"
base="$(git -C "${added}" rev-parse HEAD)"
printf '%s\n' "${_UV_HYDRA}" > "${added}/uv.lock"
t_git_commit "${added}"
_out="$(t_out _audit "${added}" osv-hydra.json --mode gate --base "${base}")"
t_assert_eq "1" "$(t_rc _audit "${added}" osv-hydra.json --mode gate --base "${base}")" \
  "a HIGH advisory absent from the base lockfile is exactly what push mode exists to stop"
t_assert_contains "${_out}" "BLOCKING: HIGH GHSA-wf6j-7hvr-gr93 hydra-core@1.3.7 is new in uv.lock"
t_assert_eq "fail" "$(_json "${added}" 'd["verdict"]')"
t_assert_eq "hydra-core@1.3.7 uv.lock HIGH" "$(_json "${added}" '" ".join((d["blocking"][0]["package"], d["blocking"][0]["lockfile"], d["blocking"][0]["severity"]))')"

t_case "an unchanged lock with a known advisory PASSES push mode and still lists it"
known="$(_repo "${_UV_HYDRA}")"
_out="$(t_out _audit "${known}" osv-hydra.json --mode gate --base HEAD)"
t_assert_eq "0" "$(t_rc _audit "${known}" osv-hydra.json --mode gate --base HEAD)" \
  "an advisory published after the pin landed is not something this commit added"
t_assert_contains "${_out}" "HIGH     GHSA-wf6j-7hvr-gr93 hydra-core@1.3.7 uv.lock known"
t_assert_eq "GHSA-wf6j-7hvr-gr93 True pass" "$(_json "${known}" '" ".join((d["findings"][0]["id"], str(d["findings"][0]["in_base"]), d["verdict"]))')"

t_case "report mode lists the new finding and succeeds"
t_assert_eq "0" "$(t_rc _audit "${added}" osv-hydra.json --mode report)" \
  "the weekly run reports every finding; it never blocks"
t_assert_eq "report 1 pass" "$(_json "${added}" '" ".join((d["mode"], str(len(d["findings"])), d["verdict"]))')"

t_case "a finding without a severity is graded HIGH"
nosev="$(mktemp -d "${_work}/repo.XXXXXX")"
git -C "${nosev}" init -q
mkdir -p "${nosev}/firmware"
printf 'crate\n' > "${nosev}/firmware/README"
t_git_commit "${nosev}"
printf '[[package]]\nname = "paste"\nversion = "1.0.15"\n' > "${nosev}/firmware/Cargo.lock"
t_git_commit "${nosev}"
t_assert_eq "1" "$(t_rc _audit "${nosev}" osv-no-severity.json --mode gate --base HEAD~1)" \
  "an advisory nobody scored may be critical, so it blocks like one"
t_assert_eq "RUSTSEC-2024-0436 HIGH" "$(_json "${nosev}" '" ".join((d["findings"][0]["id"], d["findings"][0]["severity"]))')"

t_case "...while a CVSS score below 7.0 with no database severity is MODERATE"
sed 's/"max_severity": ""/"max_severity": "5.3"/' "${FIXTURES}/osv-no-severity.json" > "${_work}/scored.json"
t_assert_eq "0" "$(t_rc _audit "${nosev}" "${_work}/scored.json" --mode gate --base HEAD~1)"
t_assert_eq "MODERATE" "$(_json "${nosev}" 'd["findings"][0]["severity"]')"

t_case "a missing scanner fails instead of reporting 0"
rm -f "${known}/security-audit.json"
_missing() { ( cd "${known}" && SECURITY_AUDIT_OSV_SCANNER="${_work}/bin/no-such-scanner" bash "${AUDIT}" --mode report ); }
t_assert_eq "2" "$(t_rc _missing)" "no scanner means nothing was graded"
t_assert_contains "$(t_out _missing)" "is not an executable file"
t_assert_eq "absent" "$(if [ -e "${known}/security-audit.json" ]; then echo present; else echo absent; fi)" \
  "a JSON written without a scan would read as a clean audit"

t_case "a scanner that crashes or writes nothing fails too"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "osv-scanner version: 2.7.0" && exit 0\nexit 127\n' > "${_work}/bin/crash"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "osv-scanner version: 2.7.0"\nexit 0\n' > "${_work}/bin/silent"
chmod +x "${_work}/bin/crash" "${_work}/bin/silent"
for fake in crash silent; do
  t_assert_eq "2" "$(t_rc env SECURITY_AUDIT_OSV_SCANNER="${_work}/bin/${fake}" bash -c "cd '${known}' && bash '${AUDIT}' --mode report")" \
    "${fake}: exit status 0 or 1 without JSON is not a scan"
done

t_case "every lockfile kind is scanned, and Cargo.lock directories get cargo_security_checks.sh"
kinds="$(_repo "${_UV_HYDRA}")"
mkdir -p "${kinds}/web" "${kinds}/firmware" "${kinds}/app" "${kinds}/third_party/vendored"
cat > "${kinds}/web/package-lock.json" <<'EOF'
{"lockfileVersion": 3, "packages": {
  "": {"name": "web"},
  "node_modules/deepmerge": {"version": "4.3.1"},
  "node_modules/glob": {"version": "10.5.0"},
  "node_modules/rimraf/node_modules/glob": {"version": "13.0.6"},
  "node_modules/minimatch": {"version": "10.2.6"},
  "node_modules/a/node_modules/minimatch": {"version": "3.1.5"},
  "node_modules/@scope/b/node_modules/minimatch": {"version": "9.0.9"}}}
EOF
printf '[[package]]\nname = "paste"\nversion = "1.0.15"\n' > "${kinds}/firmware/Cargo.lock"
printf 'packages:\n  async:\n    source: hosted\n    version: "2.13.1"\n' > "${kinds}/app/pubspec.lock"
printf 'version = 1\n' > "${kinds}/third_party/vendored/uv.lock"
t_git_commit "${kinds}"
rm -f "${_work}/cargo.log"
t_assert_eq "0" "$(t_rc _audit "${kinds}" osv-four-kinds.json --mode gate --base HEAD)"
_args="$(cat "${FAKE_OSV_ARGS}")"
for lock in uv.lock web/package-lock.json firmware/Cargo.lock app/pubspec.lock; do
  t_assert_contains "${_args}" "${kinds}/${lock}" "${lock} must reach the scanner"
done
t_assert_fails grep -q -F -e third_party <<<"${_args}"
t_assert_eq "app/pubspec.lock firmware/Cargo.lock uv.lock web/package-lock.json" \
  "$(_json "${kinds}" '" ".join(sorted(d["lockfiles"]))')"
t_assert_contains "$(cat "${_work}/cargo.log")" "${kinds}/firmware cargo audit"
t_assert_eq "firmware/Cargo.lock pass" "$(_json "${kinds}" '" ".join((d["cargo_checks"][0]["lockfile"], d["cargo_checks"][0]["status"]))')"

t_case "the base copy of every lockfile kind is parsed, so known findings stay known"
# A HIGH advisory on the pubspec package too, so all four base parsers decide the verdict.
python3 - "${FIXTURES}/osv-four-kinds.json" "${_work}/four-high.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["results"]:
    for p in r["packages"]:
        if p["package"]["name"] == "async":
            p["groups"] = [{"ids": ["GHSA-fake-pubs-pec0"], "aliases": [], "max_severity": "9.8"}]
            p["vulnerabilities"] = [{"id": "GHSA-fake-pubs-pec0"}]
json.dump(d, open(sys.argv[2], "w"))
EOF
t_assert_eq "0" "$(t_rc _audit "${kinds}" "${_work}/four-high.json" --mode gate --base HEAD)" \
  "a kind the base parser cannot read would call every one of its findings new"
t_assert_eq "0 4" "$(_json "${kinds}" '" ".join((str(sum(1 for f in d["findings"] if f["in_base"] is not True)), str(len({f["lockfile"] for f in d["findings"]}))))')"

t_case "a lockfile the scanner did not report fails"
t_assert_eq "2" "$(t_rc _audit "${kinds}" osv-hydra.json --mode report)" \
  "three of four lockfiles graded by nothing is not a clean audit"

t_summary
