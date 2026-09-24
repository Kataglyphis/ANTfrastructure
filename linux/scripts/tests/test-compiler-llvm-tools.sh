#!/usr/bin/env bash
# compiler-llvm-tools.sh picks the LLVM tools of the compiler that configured a
# build tree. Two fake LLVM installs stand in for the image's pair: the tree's
# compiler (CMakeCache.txt) and a different clang++ first on PATH, so every case
# can tell which one answered.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../lib/compiler-llvm-tools.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _fake_llvm <dir> <tool>... - a clang++ whose -print-prog-name answers with its
# sibling when that sibling exists and with the bare name otherwise, as clang does.
_fake_llvm() {
  local dir="$1" tool
  shift
  mkdir -p "${dir}/bin"
  cat > "${dir}/bin/clang++" <<'FAKE'
#!/usr/bin/env bash
tool="${1#-print-prog-name=}"
here="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "${here}/${tool}" ]]; then printf '%s\n' "${here}/${tool}"; else printf '%s\n' "${tool}"; fi
FAKE
  chmod +x "${dir}/bin/clang++"
  for tool in "$@"; do
    printf '#!/usr/bin/env bash\necho %s\n' "${dir##*/}" > "${dir}/bin/${tool}"
    chmod +x "${dir}/bin/${tool}"
  done
}
_fake_llvm "${_work}/tree-llvm" llvm-profdata llvm-cov
_fake_llvm "${_work}/path-llvm" llvm-profdata llvm-cov
_fake_llvm "${_work}/half-llvm" llvm-profdata

mkdir -p "${_work}/build" "${_work}/half-build" "${_work}/no-cache"
printf 'CMAKE_CXX_COMPILER:FILEPATH=%s\n' "${_work}/tree-llvm/bin/clang++" > "${_work}/build/CMakeCache.txt"
printf 'CMAKE_CXX_COMPILER:FILEPATH=%s\n' "${_work}/half-llvm/bin/clang++" > "${_work}/half-build/CMakeCache.txt"

# Every case runs in a fresh shell with PATH's clang++ being path-llvm's.
_in_lib() { PATH="${_work}/path-llvm/bin:${PATH}" bash -c "source '${LIB}'; $1" 2>&1; }

t_case "the tree's compiler answers, not the clang++ first on PATH"
t_assert_eq "${_work}/tree-llvm/bin/llvm-profdata" "$(_in_lib "compiler_llvm_tool '${_work}/build' llvm-profdata")"

t_case "without a CMakeCache.txt, PATH's clang++ answers"
t_assert_eq "${_work}/path-llvm/bin/llvm-cov" "$(_in_lib "compiler_llvm_tool '${_work}/no-cache' llvm-cov")"

t_case "a compiler with no such tool answers with the bare name, and that is a failure"
t_assert_eq "1" "$(_in_lib "compiler_llvm_tool '${_work}/half-build' llvm-cov >/dev/null; echo \$?")"

t_case "use_compiler_llvm_tools puts the compiler's directory first, for every named tool"
_out="$(_in_lib "use_compiler_llvm_tools '${_work}/build' llvm-profdata llvm-cov >/dev/null; llvm-profdata; llvm-cov")"
t_assert_eq "$(printf 'tree-llvm\ntree-llvm')" "${_out}" "both tools must now come from the tree's LLVM"

t_case "one tool missing beside the compiler leaves PATH alone and says so"
_out="$(_in_lib "use_compiler_llvm_tools '${_work}/half-build' llvm-profdata llvm-cov; llvm-profdata")"
t_assert_contains "${_out}" "has no llvm-cov beside llvm-profdata"
t_assert_contains "${_out}" "path-llvm" "a half set must not shadow PATH's matched pair"

t_summary
