#!/usr/bin/env bash
# verify_large_files.py: a tracked data file over 500 KiB is new, grown, shrunk or stale against large-files.allow. See docs/data-repositories.md#keeping-data-out-of-the-code-repositories
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="$(cd "${TESTS_DIR}/.." && pwd)/verify_large_files.py"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# _repo <rel> <KiB> <kind: bin|text> [allow]: a consumer checkout tracking one file of that size.
_repo() {
  local d; d="$(mktemp -d "${_work}/repo.XXXXXX")"
  mkdir -p "${d}/$(dirname "$1")"
  if [ "$3" = bin ]; then
    { printf 'x\0'; head -c $(( $2 * 1024 - 2 )) /dev/zero | tr '\0' 'y'; } > "${d}/$1"
  else
    head -c $(( $2 * 1024 )) /dev/zero | tr '\0' 'a' > "${d}/$1"
  fi
  [ -z "${4-}" ] || printf '%s\n' "$4" > "${d}/large-files.allow"
  git -C "${d}" init -q && git -C "${d}" add -A && git -C "${d}" commit -q -m fixture
  printf '%s' "${d}"
}

_rc() { t_rc "${PY}" "${GATE}" --root "$1"; }
_out() { t_out "${PY}" "${GATE}" --root "$1"; }

t_case "under the limit, or text that is not data, passes"
t_assert_eq 0 "$(_rc "$(_repo assets/small.bin 400 bin)")" "400 KiB is under the limit"
t_assert_eq 0 "$(_rc "$(_repo uv.lock 900 text)")" "a 900 KiB lockfile is source, not data"

t_case "a new large binary fails and names the freeze file"
d="$(_repo assets/model.bin 900 bin)"
t_assert_eq 1 "$(_rc "${d}")" "an unfrozen 900 KiB binary fails"
t_assert_contains "$(_out "${d}")" "large-files.allow" "the failure says where a freeze goes"
t_assert_contains "$(_out "${d}")" "ModelANT or AssetANT" "and where the data belongs instead"

t_case "a data format fails even as text: a scene .obj, a PDF without a NUL byte"
t_assert_eq 1 "$(_rc "$(_repo Resources/scene.obj 900 text)")" "a 900 KiB .obj is a scene"
t_assert_eq 1 "$(_rc "$(_repo docs/paper.PDF 900 text)")" "a PDF is a document, whatever its first bytes"

t_case "a frozen file at its size passes; growth, shrink and a stale freeze fail"
t_assert_eq 0 "$(_rc "$(_repo assets/model.bin 900 bin 'assets/model.bin | 900 | the runtime loads it')")" "the baseline is the contract"
t_assert_eq 1 "$(_rc "$(_repo assets/model.bin 950 bin 'assets/model.bin | 900 | the runtime loads it')")" "growth fails"
t_assert_eq 1 "$(_rc "$(_repo assets/model.bin 850 bin 'assets/model.bin | 900 | the runtime loads it')")" "a shrink must be recorded"
t_assert_eq 1 "$(_rc "$(_repo assets/small.bin 10 bin 'assets/gone.bin | 900 | moved to AssetANT')")" "a freeze nothing matches is stale"

t_case "vendored third_party/ and symlinks are not this repo's data"
t_assert_eq 0 "$(_rc "$(_repo third_party/lib/test.png 900 bin)")" "third_party is graded by its own repository"
d="$(_repo assets/small.bin 10 bin)"
head -c $(( 900 * 1024 )) /dev/zero > "${_work}/outside.bin"
ln -s "${_work}/outside.bin" "${d}/assets/link.bin" && git -C "${d}" add -A && git -C "${d}" commit -q -m link
t_assert_eq 0 "$(_rc "${d}")" "a symlink is a path, not data"
d="$(_repo assets/small.bin 10 bin)"
ln -s ../third_party/absent/custom.css "${d}/assets/custom.css" && git -C "${d}" add -A && git -C "${d}" commit -q -m dangling
t_assert_eq 0 "$(_rc "${d}")" "a symlink into an absent submodule does not make the tree partial"
rm "${d}/assets/small.bin"
t_assert_eq 2 "$(_rc "${d}")" "a missing regular file still makes it partial: exit 2, nothing graded"

t_summary
