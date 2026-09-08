#!/usr/bin/env bash
# Tests for verify_dockerfile_context_paths.py. The load-bearing case is the
# ARCHIVE SWEEP that prompted the gate: the script still exists, just not where
# the mount says. NO "the real tree is green" case belongs here -- the mutation
# gate mirrors the repo without linux/webserver/dist, so one would fail in every
# mutation workspace for a reason unrelated to the mutation; preflight owns the
# whole-tree answer.
# docs/code-quality-tooling.md#dockerfile-context-paths-context-paths
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"

# _tree — a throwaway repo root holding the gate. Callers add Dockerfiles.
_tree() {
  local d; d="$(t_gate_tree verify_dockerfile_context_paths.py)"
  mkdir -p "${d}/windows/scripts/diagnostics/archive" "${d}/linux/scripts/01-core"
  printf '%s' "${d}"
}

_gate() { "${PY}" "$1/linux/scripts/verify_dockerfile_context_paths.py"; }
# _df <path> <line>... — append instruction lines to a Dockerfile.
_df() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${@:2}" >> "$1"; }
# _expect <rc> <fixture> <needle> <why> — verdict AND the report line that
# justifies it, in one place: a red for the wrong path is not this gate working.
_expect() {
  t_assert_eq "$1" "$(t_rc _gate "$2")" "$4"
  t_assert_contains "$(t_out _gate "$2")" "$3" "$4"
}
# _track_all <fixture> — turn it into a work tree with everything in it tracked,
# which is the only way the gate's tracked-only scope is observable at all.
# The tracking half is t_git_commit's, the harness owner t_consumer_fixture uses:
# spelling `git add -A` here again is the copy the dupe gate names, and ending the
# function on `init -q && add` is the trailing conditional that returns the false
# arm's 1 on a fixture that had nothing to stage.
_track_all() {
  git -C "$1" init -q
  t_git_commit "$1"
}
# _seeded <repo-relative path> — a fixture with one throwaway file already in it.
_seeded() { local d; d="$(_tree)"; mkdir -p "$(dirname "${d}/$1")"; printf 'x\n' > "${d}/$1"; printf '%s' "${d}"; }
# _per_dockerfile <fixture> <declaring Dockerfile> <other> <instruction> — the
# same instruction is legal in the one a table names and broken in the other.
_per_dockerfile() {
  _df "$1/$2" 'FROM scratch' "$4"
  t_assert_eq "0" "$(t_rc _gate "$1")" "$2 is what the table names"
  _df "$1/$3" 'FROM scratch' "$4"
  t_assert_eq "1" "$(t_rc _gate "$1")" "$3 is not, and one entry must not cover both"
}

t_case "a COPY whose source is in the context passes"
fix="$(_tree)"
printf 'true\n' > "${fix}/linux/scripts/01-core/entry.sh"
_df "${fix}/linux/Dockerfile.base" 'FROM scratch' \
    'COPY linux/scripts/01-core/entry.sh /opt/scripts/entry.sh'
_expect 0 "${fix}" "every COPY and bind-mount source resolves" \
  "the gate must be able to be green, or every red below proves nothing"

t_case "a COPY source that is not in the context FAILS, and is named with its line"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.base" 'FROM scratch' \
    'COPY linux/scripts/01-core/gone.sh /opt/scripts/gone.sh'
_expect 1 "${fix}" "linux/scripts/01-core/gone.sh" \
  "BuildKit fails this at context checksum, before instruction one"
t_assert_contains "$(t_out _gate "${fix}")" "L2:" "the finding has to say WHERE"

t_case "a bind mount source that is not in the context FAILS"
# Dockerfile.probe's shape: a mount of windows/upstream/sccache-nvcc-quote-fix
# after #137 deleted it. Every -ProbeScript solve died, live probes included.
fix="$(_tree)"
_df "${fix}/windows/Dockerfile.probe" 'FROM scratch' \
    'RUN --mount=type=bind,source=windows/upstream/deleted-tree,target=C:\bkmnt\patch true'
_expect 1 "${fix}" "windows/upstream/deleted-tree" \
  "a COPY-only check would call this Dockerfile healthy"

t_case "the ARCHIVE SWEEP shape: present under archive/, mounted at the old path"
fix="$(_tree)"
printf 'exit 0\n' > "${fix}/windows/scripts/diagnostics/archive/Test-SccacheWrite.ps1"
_df "${fix}/windows/Dockerfile.sccache-write-probe" 'FROM scratch' \
    'RUN --mount=type=bind,source=windows/scripts/diagnostics/Test-SccacheWrite.ps1,target=C:\bkmnt\x.ps1 true'
_expect 1 "${fix}" "windows/scripts/diagnostics/Test-SccacheWrite.ps1" \
  "the file existing SOMEWHERE is not the same as existing where the mount says"

t_case "and it passes once the script is moved back to the path the mount names"
mv "${fix}/windows/scripts/diagnostics/archive/Test-SccacheWrite.ps1" \
   "${fix}/windows/scripts/diagnostics/Test-SccacheWrite.ps1"
t_assert_eq "0" "$(t_rc _gate "${fix}")" "moving the file is the fix; the gate has to agree"

t_case "a Windows Dockerfile's backtick continuation is followed, not the backslash default"
# `# escape=\`` is why these files can spell C:\paths at all. The operands here
# sit ENTIRELY on the continuation line, which is the shape that goes invisible
# when nothing folds: "COPY \`" alone carries no source, and the next raw line
# does not start with COPY, so an unfolded read reports a clean Dockerfile.
fix="$(_tree)"
_df "${fix}/windows/Dockerfile.media-builder" '# escape=`' \
    'FROM scratch' \
    'COPY `' \
    '    windows\scripts\absent.ps1 C:\temp\absent.ps1'
_expect 1 "${fix}" 'windows\scripts\absent.ps1' \
  "an unfolded continuation hides every operand that is not on the first line"

t_case "a backslash-joined COPY in a normal Dockerfile is followed too"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.sdk" 'FROM scratch' \
    'COPY --chmod=755 \' \
    '  linux/scripts/01-core/absent.sh \' \
    '  /opt/scripts/absent.sh'
_expect 1 "${fix}" "linux/scripts/01-core/absent.sh" \
  "the default joiner is the backslash, and this is the shape it exists for"

t_case "COPY --from= and mount from= name a STAGE, not the context, and are not judged"
# Both sources here are spelled RELATIVE on purpose: an absolute one would be
# skipped anyway, and the guard being tested would go unproven.
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.package" 'FROM scratch AS artifact-source' \
    'FROM scratch' \
    'COPY --link --from=artifact-source opt/onnxruntime /opt/onnxruntime' \
    'RUN --mount=type=bind,from=artifact-source,source=opt/flutter,target=/artifact-src true'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "grading a stage path against the host tree is a guaranteed false red"

t_case "a Windows-spelled COPY source is normalised, so a broken one is still caught"
fix="$(_tree)"
_df "${fix}/windows/Dockerfile" 'FROM scratch' \
    'COPY windows\scripts\diagnostics\absent.ps1 C:\temp\scripts\'
_expect 1 "${fix}" "absent.ps1" "backslashes are separators here, not part of the name"

t_case "an absolute or URL source is not a context path"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.torch" 'FROM scratch' \
    'ADD https://example.invalid/x.tgz /tmp/x.tgz' \
    'COPY /etc/hosts /tmp/hosts'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "neither is fetched from the build context"

t_case "a \${VAR} segment is a wildcard: it passes when SOME concrete path exists"
fix="$(_tree)"
mkdir -p "${fix}/linux/scripts/03-media/build/gstreamer/android"
printf 'true\n' > "${fix}/linux/scripts/03-media/build/gstreamer/android/build.sh"
_df "${fix}/linux/Dockerfile.android" 'FROM scratch' \
    'COPY --chmod=755 linux/scripts/03-media/build/${ANDROID_LIB}/android/ /opt/scripts/a/'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "which value the build arg takes is not a static fact"

t_case "and a \${VAR} path with NO concrete match still fails"
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.android" 'FROM scratch' \
    'COPY --chmod=755 linux/scripts/03-media/nothing/${ANDROID_LIB}/android/ /opt/scripts/a/'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "a wildcard that matches nothing is still a broken reference"

t_case "the CONTEXTS table is keyed per Dockerfile, and cannot widen to a second one"
# windows/Dockerfile.nvidia is solved with -Context 'windows'; its siblings are
# solved from the repo root. Same check for both tables, so one owner: an entry
# that leaked to every image would silence the class the gate exists for.
_per_dockerfile "$(_seeded windows/scripts/diagnostics/probe.ps1)" \
  windows/Dockerfile.nvidia windows/Dockerfile.base \
  'COPY scripts/diagnostics/probe.ps1 C:\probe.ps1'

t_case "the GENERATED table is keyed per Dockerfile too"
_per_dockerfile "$(_tree)" linux/llm-stack/Dockerfile linux/Dockerfile.torch \
  'COPY ollama-binary.tar.zst /tmp/ollama.tar.zst'

t_case "a Dockerfile whose whole context is generated at run time is off-subject"
fix="$(_tree)"
_df "${fix}/windows/scripts/diagnostics/probe-build-copy/Dockerfile" 'FROM scratch' \
    'COPY hello.txt C:\hello.txt'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "Test-BuildCopy.ps1 mints the context; no path here can stand in for it"

t_case "Dockerfile.X.Tests.ps1 is a test ABOUT a Dockerfile, not a subject"
fix="$(_tree)"
mkdir -p "${fix}/windows/scripts/tests"
_df "${fix}/windows/scripts/tests/Dockerfile.ProbeShell.Tests.ps1" 'COPY nope.txt C:\nope.txt'
_df "${fix}/linux/Dockerfile.base" 'FROM scratch'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a .ps1 is PowerShell; parsing it as a Dockerfile invents findings"

t_case "in a work tree, an UNTRACKED Dockerfile is not graded and a tracked one is"
# A local clone has its own build contract; grading it put four findings nobody
# in this repo can act on in front of the two real ones.
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.base" 'FROM scratch'
_track_all "${fix}"
_df "${fix}/scratch-clone/Dockerfile" 'FROM scratch' 'COPY pyproject.toml /tmp/p'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "an untracked checkout is not one of this repo's Dockerfiles"
_df "${fix}/linux/Dockerfile.base" 'COPY linux/scripts/01-core/absent.sh /tmp/a'
t_assert_eq "1" "$(t_rc _gate "${fix}")" "while the tracked one is still graded"

t_case "external/ is skipped even where git cannot answer at all"
# The floor under the case above: no work tree here, so `git ls-files` reports
# nothing and every Dockerfile found is graded — except the named scratch root.
fix="$(_tree)"
_df "${fix}/linux/Dockerfile.base" 'FROM scratch'
_df "${fix}/external/Vendored/Dockerfile" 'FROM scratch' 'COPY pyproject.toml /tmp/p'
t_assert_eq "0" "$(t_rc _gate "${fix}")" "a mirror or a bind mount without .git must not turn external/ into findings"

t_case "a tree with no Dockerfiles fails instead of reporting a clean sweep"
fix="$(t_gate_tree verify_dockerfile_context_paths.py)"
_expect 1 "${fix}" "no Dockerfiles found" "zero subjects is a broken checkout, not a pass"

t_summary
