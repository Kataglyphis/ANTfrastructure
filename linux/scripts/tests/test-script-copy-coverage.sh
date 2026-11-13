#!/usr/bin/env bash
# verify_script_copy_coverage.py on throwaway roots, since it scans from its own path; see docs/code-quality-tooling.md#script-copy-coverage-copy-coverage
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree [<name>]: a repo root holding the gate, with an empty linux/Dockerfile.<name>.
_tree() {
  local d; d="$(t_gate_tree verify_script_copy_coverage.py)"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/linux/scripts/03-media/core"
  : > "${d}/linux/Dockerfile.${1:-base}"
  printf '%s' "${d}"
}

_gate() { "${PY}" "$1/linux/scripts/verify_script_copy_coverage.py" "${@:2}"; }
_df() { printf '%s\n' "${@:2}" >> "$1"; }

_entry_fixture() {
  fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
  printf '%s\n' "$1" > "${fix}/linux/scripts/01-core/entry.sh"
  _df "${df}" 'COPY linux/scripts/01-core/entry.sh /opt/scripts/core/entry.sh' \
             'RUN bash /opt/scripts/core/entry.sh'
}

_bundle_transport_controls() {
  local header="$1" stage="$2" source="${3:-/}" transport _out
  for transport in mount copy; do
    printf '%s\n' "${header}" > "${df}"
    if [ "${transport}" = mount ]; then
      _df "${df}" "RUN --mount=type=bind,from=${stage},source=${source},target=/opt/scripts,ro bash /opt/scripts/core/entry.sh"
    else
      _df "${df}" "COPY --from=${stage} ${source%/}/ /opt/scripts/" 'RUN bash /opt/scripts/core/entry.sh'
    fi
    t_assert_eq 0 "$(t_rc _gate "${fix}")"
    _out="$(t_out _gate "${fix}" --provided-scripts Dockerfile.base)"
    t_assert_ok "${PY}" -c 'import json,sys; assert json.loads(sys.argv[1]) == {"/opt/scripts/core/entry.sh": "linux/scripts/01-core/entry.sh"}' "${_out}"
    sed -i "s/from=${stage}/from=unknown-context/" "${df}"
    t_assert_eq 1 "$(t_rc _gate "${fix}")"
  done
}

t_case "a RUN whose script was COPY'd passes"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'echo hi\n' > "${fix}/linux/scripts/01-core/entry.sh"
_df "${df}" 'COPY linux/scripts/01-core/entry.sh /opt/scripts/core/entry.sh' \
            'RUN bash /opt/scripts/core/entry.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "the gate must be able to be green, or the reds below prove nothing"
t_assert_contains "$(t_out _gate "${fix}")" "all referenced /opt/scripts paths are provided"

t_case "a RUN referencing a script that was never COPY'd FAILS, and names it"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
_df "${df}" 'RUN bash /opt/scripts/core/never-copied.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "exit 127 deep inside a multi-hour build is what this replaces"
t_assert_contains "$(t_out _gate "${fix}")" "/opt/scripts/core/never-copied.sh"

t_case "a TRANSITIVE reference is followed: the sourced script must be provided too"
# The COPY'd script sources a path the image never had.
_entry_fixture 'source /opt/scripts/03-media/core/common.sh'
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a direct-references-only check would call this image complete"
t_assert_contains "${_out}" "/opt/scripts/03-media/core/common.sh"

t_case "and it passes once that transitive dependency is COPY'd"
printf 'true\n' > "${fix}/linux/scripts/03-media/core/common.sh"
_df "${df}" 'COPY linux/scripts/03-media/core/ /opt/scripts/03-media/core/'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a directory COPY provides every *.sh beneath it"

t_case "a bare string literal counts as a reference, not only a bash invocation"
# A `for f in "/opt/scripts/..."; do source "$f"; done` loop never spells out a command.
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'for f in "/opt/scripts/core/helper.sh"; do source "$f"; done\n' \
  > "${fix}/linux/scripts/01-core/loop.sh"
_df "${df}" 'COPY linux/scripts/01-core/loop.sh /opt/scripts/core/loop.sh' \
            'RUN bash /opt/scripts/core/loop.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" "/opt/scripts/core/helper.sh"

t_case "a per-RUN bind mount provides the script for that RUN"
# Counting only COPY would fail a healthy tree.
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'true\n' > "${fix}/linux/scripts/01-core/mounted.sh"
_df "${df}" 'RUN --mount=type=bind,source=linux/scripts/01-core,target=/opt/scripts/core,ro bash /opt/scripts/core/mounted.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")"

t_case "a COPY split across line continuations still counts"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
printf 'true\n' > "${fix}/linux/scripts/01-core/wrapped.sh"
_df "${df}" 'COPY --chmod=755 \' \
            '  linux/scripts/01-core/wrapped.sh \' \
            '  /opt/scripts/core/wrapped.sh' \
            'RUN bash /opt/scripts/core/wrapped.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a logical line that is not joined provides nothing and fails a healthy tree"

t_case "an inherited path listed in KNOWN_BASE_PROVIDED is allowed, and only for its Dockerfile"
# Keyed by Dockerfile, so an entry cannot silence the check for every image.
fix="$(_tree media)"
_df "${fix}/linux/Dockerfile.media" 'RUN bash /opt/scripts/toolchain/vulkan.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "vulkan.sh comes from the sdk FROM base"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.base" 'RUN bash /opt/scripts/toolchain/vulkan.sh'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "the same path is not inherited by Dockerfile.base"

t_case "a tree with no Dockerfiles fails instead of reporting a clean sweep"
fix="$(t_gate_tree verify_script_copy_coverage.py)"
mkdir -p "${fix}/linux"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "zero subjects is a broken checkout, not a pass"
t_assert_contains "$(t_out _gate "${fix}")" "no Dockerfiles found"

t_case "one missing reference in one Dockerfile fails the whole run"
fix="$(_tree)"; _tree_second="${fix}/linux/Dockerfile.media"
printf 'true\n' > "${fix}/linux/scripts/01-core/ok.sh"
_df "${fix}/linux/Dockerfile.base" 'COPY linux/scripts/01-core/ok.sh /opt/scripts/core/ok.sh' \
                                   'RUN bash /opt/scripts/core/ok.sh'
_df "${_tree_second}" 'RUN bash /opt/scripts/core/absent.sh'
_out="$(t_out _gate "${fix}")"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a green Dockerfile must not carry a red one through"
t_assert_contains "${_out}" "missing script reference(s)"

t_case "--report-core-usage is read-only and never fails"
# The report's figure is only a lower bound, so no verdict may hang on it.
fix="$(_tree)"
printf 'true\n' > "${fix}/linux/scripts/01-core/used.sh"
_df "${fix}/linux/Dockerfile.base" 'RUN --mount=type=bind,source=linux/scripts/01-core,target=/opt/scripts/core bash /opt/scripts/core/absent-from-mount.sh'
t_assert_eq "0" "$(t_rc _gate "${fix}" --report-core-usage)" "the report must not inherit the gate's verdict"
t_assert_eq "1" "$(t_rc _gate "${fix}")" "while the gate itself still fails on the same tree"

t_case "policy hashes and other suffixes do not invent script references"
_entry_fixture $'cat /opt/scripts/core/backend-source-notices.sha256\ncat /opt/scripts/core/rocmlir-source-notices.sha256\ncat /opt/scripts/core/template.sh.in\nsource "/opt/scripts/core/needed.sh"'
_out="$(t_out _gate "${fix}")"
t_assert_eq 1 "$(t_rc _gate "${fix}")"
t_assert_contains "${_out}" '/opt/scripts/core/needed.sh'
t_assert_fails grep -F -q -e '/opt/scripts/core/backend-source-notices.sh' <<< "${_out}"
t_assert_fails grep -F -q -e '/opt/scripts/core/rocmlir-source-notices.sh' <<< "${_out}"
t_assert_fails grep -F -q -e '/opt/scripts/core/template.sh' <<< "${_out}"
printf 'true\n' > "${fix}/linux/scripts/01-core/needed.sh"
_df "${df}" 'COPY linux/scripts/01-core/needed.sh /opt/scripts/core/needed.sh'
t_assert_eq 0 "$(t_rc _gate "${fix}")"

t_case "a selected-file producer provides scripts only through its declared stage transport"
fix="$(_tree)"; df="${fix}/linux/Dockerfile.base"
cp "${TESTS_DIR}/../script_closure.py" "${TESTS_DIR}/../stage-script-closure.py" "${fix}/linux/scripts/"
mkdir "${fix}/linux/scripts/script-closures"
printf 'true\n' > "${fix}/linux/scripts/01-core/entry.sh"
printf '01-core/entry.sh|core/entry.sh\n' > "${fix}/linux/scripts/script-closures/shared.txt"
printf '@shared\n' > "${fix}/linux/scripts/script-closures/fixture.txt"
_bundle_header=$'FROM image AS source-bundle\nRUN --mount=type=bind,source=linux/scripts,target=/script-sources,ro python3 /script-sources/stage-script-closure.py fixture\nFROM image'
_bundle_transport_controls "${_bundle_header}" source-bundle /script-bundle
printf '%s\n' "${_bundle_header}" > "${df}"
_df "${df}" 'RUN bash /opt/scripts/core/entry.sh'
t_assert_eq 1 "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" '/opt/scripts/core/entry.sh'
printf '%s\n' "${_bundle_header}" > "${df}"
_df "${df}" 'COPY --from=wrong-stage /script-bundle/ /opt/scripts/' 'RUN bash /opt/scripts/core/entry.sh'
t_assert_eq 1 "$(t_rc _gate "${fix}")"

t_case "a bundle producer requires the selected file, loader and transitive profile inputs"
for omitted in stage-script-closure.py script_closure.py script-closures/shared.txt 01-core/entry.sh; do
  printf 'FROM image AS source-bundle\n' > "${df}"
  _producer='RUN'
  for input in stage-script-closure.py script_closure.py script-closures/shared.txt script-closures/fixture.txt 01-core/entry.sh; do
    if [ "${input}" = "${omitted}" ]; then continue; fi
    _producer+=" --mount=type=bind,source=linux/scripts/${input},target=/script-sources/${input},ro"
  done
  _df "${df}" "${_producer} python3 /script-sources/stage-script-closure.py fixture" 'FROM image' \
    'RUN --mount=type=bind,from=source-bundle,source=/script-bundle,target=/opt/scripts,ro bash /opt/scripts/core/entry.sh'
  t_assert_eq 1 "$(t_rc _gate "${fix}")" "the producer must reject the missing ${omitted}"
  t_assert_contains "$(t_out _gate "${fix}")" '/opt/scripts/core/entry.sh'
done

t_case "an unnamed producer cannot overwrite a previous named stage"
printf '01-core/entry.sh|core/other.sh\n' > "${fix}/linux/scripts/script-closures/other.txt"
printf '%s\n' "${_bundle_header/closure.py fixture/closure.py other}" > "${df}"
_df "${df}" 'RUN --mount=type=bind,source=linux/scripts,target=/script-sources,ro python3 /script-sources/stage-script-closure.py fixture' \
  'RUN --mount=type=bind,from=source-bundle,source=/script-bundle,target=/opt/scripts,ro bash /opt/scripts/core/entry.sh'
t_assert_eq 1 "$(t_rc _gate "${fix}")"
t_assert_contains "$(t_out _gate "${fix}")" '/opt/scripts/core/entry.sh'

t_case "the declared-script map is machine-readable and its CLI rejects invalid requests"
printf '%s\n' "${_bundle_header}" > "${df}"
_df "${df}" 'RUN --mount=type=bind,from=source-bundle,source=/script-bundle,target=/opt/scripts,ro bash /opt/scripts/core/entry.sh'
_out="$(t_out _gate "${fix}" --provided-scripts Dockerfile.base)"
t_assert_eq 0 "$(t_rc _gate "${fix}" --provided-scripts Dockerfile.base)"
t_assert_ok "${PY}" -c 'import json,sys; assert json.loads(sys.argv[1]) == {"/opt/scripts/core/entry.sh": "linux/scripts/01-core/entry.sh"}' "${_out}"
t_assert_eq 2 "$(t_rc _gate "${fix}" --provided-scripts)"
cp "${df}" "${fix}/Dockerfile.base"
t_assert_eq 2 "$(t_rc _gate "${fix}" --provided-scripts ../Dockerfile.base)"
t_assert_eq 2 "$(t_rc _gate "${fix}" --provided-scripts Dockerfile.absent)"
t_assert_eq 2 "$(t_rc _gate "${fix}" --provided-scripts Dockerfile.base extra)"

t_case "a declared external context provides only the files actually transported"
_bundle_transport_controls $'FROM image\nLABEL org.kataglyphis.build-script-closure=fixture' hub-scripts ''
_bundle_transport_controls $'FROM hub-scripts AS selected-scripts\nFROM image\nLABEL org.kataglyphis.build-script-closure=fixture' selected-scripts ''
printf 'FROM image\nLABEL org.kataglyphis.build-script-closure=fixture\nRUN bash /opt/scripts/core/entry.sh\n' > "${df}"
t_assert_eq 1 "$(t_rc _gate "${fix}")" "a label alone transports no files"
for label in '' 'LABEL org.kataglyphis.build-script-closure=absent' 'LABEL org.kataglyphis.build-script-closure=bad_profile' $'LABEL org.kataglyphis.build-script-closure=fixture\nLABEL org.kataglyphis.build-script-closure=fixture'; do
  printf 'FROM image\n%s\nCOPY --from=hub-scripts / /opt/scripts/\nRUN bash /opt/scripts/core/entry.sh\n' "${label}" > "${df}"
  t_assert_fails _gate "${fix}"
done

t_case "the REAL tree is covered today"
t_assert_eq "0" "$(t_rc "${PY}" "${TESTS_DIR}/../verify_script_copy_coverage.py")"

t_summary
