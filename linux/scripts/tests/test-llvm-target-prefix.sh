#!/usr/bin/env bash
# The /opt/llvm-target repair: what fills the prefix, and what must never fill it.
# A glob over the builder's multiarch dir shipped five x86-64 libs into both
# foreign images; the rule is now DT_NEEDED-driven and lives in ONE owner.
# docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MAT="${TESTS_DIR}/../02-toolchain/materialize-llvm-target.sh"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

_ELF_NEEDED_SRC="$(t_fn_src "${MAT}" _elf_needed)" || exit 1
_FILL_SRC="$(t_fn_src "${MAT}" _llvm_target_fill_needed)" || exit 1

# ── _elf_needed reads NEEDED and only NEEDED ────────────────────────────────
t_case "_elf_needed returns the NEEDED sonames, never SONAME or RUNPATH"
# Verbatim shape of `readelf -d` on the shipped /usr/local/llvm-target/bin/clang:
# the SONAME and RUNPATH lines carry [brackets] too, and a rule that matched them
# would have the prefix chasing its own name (libLLVM.so.21.1 read as a consumer
# of itself was exactly the misreading this suite exists to prevent).
_RE_BIN="$(mktemp -d)"
cat > "${_RE_BIN}/readelf" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Dynamic section at offset 0x8f5000 contains 33 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libLLVM.so.23.1]
 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]
 0x000000000000000e (SONAME)             Library soname: [libclang-cpp.so.21.1]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]
OUT
STUB
chmod +x "${_RE_BIN}/readelf"
_needed="$(PATH="${_RE_BIN}:${PATH}" bash -c "${_ELF_NEEDED_SRC}"$'\n_elf_needed /any')"
t_assert_eq "libLLVM.so.23.1 libstdc++.so.6" "$(echo ${_needed})" \
  "both NEEDED entries, in order"
t_assert_eq "" "$(printf '%s\n' "${_needed}" | grep -e 'libclang-cpp.so.21.1' -e ORIGIN)" \
  "a SONAME or RUNPATH read as a NEEDED makes a lib look like its own consumer"
rm -rf "${_RE_BIN}"

# ── _llvm_target_fill_needed over a fixture prefix ──────────────────────────
# NEEDED_MAP is "<basename> <soname>..." per line: the fill's only view of an ELF,
# so the fixture files can be empty and the run costs no compiler.
_fill() {
  local prefix="$1" src="$2" map="$3"
  NEEDED_MAP="${map}" bash -c '
    _elf_needed() {
      printf "%s\n" "${NEEDED_MAP}" | awk -v f="${1##*/}" "\$1 == f { for (i=2; i<=NF; i++) print \$i }"
    }
    '"${_FILL_SRC}"'
    _llvm_target_fill_needed "$1" "$2"' _ "${prefix}" "${src}"
}

# The builder's multiarch dir, as measured in the amd64 artifact image: the pinned
# release beside Ubuntu's llvm-20 and llvm-21, which is why a glob over it is wrong.
_mk_fixture() {
  _P="$(mktemp -d)"; _S="$(mktemp -d)"
  mkdir -p "${_P}/bin" "${_P}/lib"
  : > "${_P}/bin/clang"
  local _l
  for _l in libLLVM.so.20.1 libLLVM.so.21.1 libLLVM.so.23.1 \
            libclang-21.so.21 libclang-23.so.23 \
            libclang-cpp.so.21.1 libclang-cpp.so.23.1 libc.so.6; do
    printf 'real %s\n' "${_l}" > "${_S}/${_l}"
  done
}
_lib_names() { (cd "$1/lib" && LC_ALL=C ls) | LC_ALL=C sort | tr '\n' ' '; }

t_case "only the NEEDED soname is filled -- the Ubuntu llvm-20/21 libs are not"
_mk_fixture
_fill "${_P}" "${_S}" "clang libLLVM.so.23.1"
t_assert_eq "libLLVM.so.23.1 " "$(_lib_names "${_P}")" \
  "HT3: a glob over the same source dir shipped five x86-64 libs into both foreign images"
t_assert_eq "real libLLVM.so.23.1" "$(cat "${_P}/lib/libLLVM.so.23.1")" "the real bytes, not a stub"
rm -rf "${_P}" "${_S}"

t_case "a non-LLVM NEEDED is left to the system loader"
_mk_fixture
_fill "${_P}" "${_S}" "clang libLLVM.so.23.1 libc.so.6"
t_assert_eq "libLLVM.so.23.1 " "$(_lib_names "${_P}")" "libc belongs to the ldconfig cache, not the prefix"
rm -rf "${_P}" "${_S}"

t_case "a dangling dev symlink is replaced by the real soname"
# The apt LLVM tree ships lib/<soname> as a link into the multiarch dir it was
# copied away from: -e is FALSE for it, and cp refuses to write through it.
_mk_fixture
ln -s ../../x86_64-linux-gnu/libLLVM.so.23.1 "${_P}/lib/libLLVM.so.23.1"
_fill "${_P}" "${_S}" "clang libLLVM.so.23.1"
t_assert_ok test -f "${_P}/lib/libLLVM.so.23.1"
t_assert_eq "real libLLVM.so.23.1" "$(cat "${_P}/lib/libLLVM.so.23.1")" "the dangling link must not survive"
rm -rf "${_P}" "${_S}"

t_case "a real file already in the prefix is never overwritten"
_mk_fixture
printf 'source-built\n' > "${_P}/lib/libLLVM.so.23.1"
_fill "${_P}" "${_S}" "clang libLLVM.so.23.1"
t_assert_eq "source-built" "$(cat "${_P}/lib/libLLVM.so.23.1")" \
  "the foreign arches' source-built libs must not be replaced by the builder's"
rm -rf "${_P}" "${_S}"

t_case "a lib pulled in by a lib is reached -- the fill runs to a fixed point"
_mk_fixture
_fill "${_P}" "${_S}" "clang libclang-cpp.so.23.1
libclang-cpp.so.23.1 libLLVM.so.23.1"
t_assert_eq "libLLVM.so.23.1 libclang-cpp.so.23.1 " "$(_lib_names "${_P}")" \
  "one pass would leave libclang-cpp with an unresolved NEEDED"
rm -rf "${_P}" "${_S}"

t_case "a soname the source dir does not have is left for the NEEDED walk to fail"
_mk_fixture
_fill "${_P}" "${_S}" "clang libLLVM.so.99.9"
t_assert_eq "" "$(_lib_names "${_P}")" "the fill never invents a lib; the hard gate below it reports the gap"
rm -rf "${_P}" "${_S}"

t_case "the fill terminates on a cycle instead of hanging the sdk stage"
_mk_fixture
printf 'real %s\n' a > "${_S}/libLLVMa.so"; printf 'real %s\n' b > "${_S}/libLLVMb.so"
_fill "${_P}" "${_S}" "clang libLLVMa.so
libLLVMa.so libLLVMb.so
libLLVMb.so libLLVMa.so" &
_pid=$!
( sleep 30; kill -9 "${_pid}" 2>/dev/null ) & _watch=$!
wait "${_pid}"; _rc=$?
kill "${_watch}" 2>/dev/null
t_assert_eq 0 "${_rc}" "the round bound must stop the loop, not a timeout"
rm -rf "${_P}" "${_S}"

# ── one owner: the walk below the fill reads the same DT_NEEDED ─────────────
t_case "the sdk stage calls the fill and the walk shares its NEEDED reader"
_MAT_SRC="$(cat "${MAT}")"
t_assert_contains "${_MAT_SRC}" "_llvm_target_fill_needed /opt/llvm-target /usr/lib/x86_64-linux-gnu" \
  "the amd64 branch must actually call it"
t_assert_eq 2 "$(printf '%s\n' "${_MAT_SRC}" | grep -c -e '_elf_needed "')" \
  "the fill and the self-containment walk are the two callers of one reader"
t_assert_eq "" "$(printf '%s\n' "${_MAT_SRC}" | grep -e 'x86_64-linux-gnu/libLLVM\*' -e 'x86_64-linux-gnu/libclang\*')" \
  "the multiarch glob is what shipped llvm-20/21 into the prefix"

# ── the package stage keeps the loader path and nothing else ────────────────
t_case "the package stage no longer copies into the llvm-target prefix"
_PAY_SRC="$(cat "${PAY}")"
t_assert_eq "" "$(printf '%s\n' "${_PAY_SRC}" | grep -e 'llvm-target/lib/\${')" \
  "the second copy of the fill is gone; materialize-llvm-target.sh is the one owner"
t_assert_eq "" "$(printf '%s\n' "${_PAY_SRC}" | grep -e 'repair_llvm_target_sonames')" \
  "a call left behind after the function went would break every package build"

t_case "the loader-path half is kept -- import tvm depends on it"
_PUB_SRC="$(t_fn_src "${PAY}" publish_llvm_target_ld_path)" || exit 1
t_assert_contains "${_PUB_SRC}" "/etc/ld.so.conf.d/000-llvm-target.conf" \
  "libtvm_compiler.so's DT_NEEDED libLLVM.so.<ver> resolves through this and nothing else"
t_assert_contains "${_PUB_SRC}" "ldconfig" "a conf file nothing reads is not a loader path"
t_assert_contains "${_PAY_SRC}" "  publish_llvm_target_ld_path" "main must call it"
t_assert_contains "${_PUB_SRC}" "000-" "it must sort before the multiarch dir"

# ── the frozen table moved with the fix ─────────────────────────────────────
t_case "no builder-arch finding is frozen any more"
eval "$(sed -n '/^_RT_TREE_ARCH_FROZEN=/p' "${SMOKE}")"
t_assert_eq "" "${_RT_TREE_ARCH_FROZEN}" \
  "the five llvm-target x86-64 libs were fixed at the source, so their rows go too"

t_case "the freeze mechanism still reports a known count and a moved one"
# Emptying the table must not leave a dead arm: the next finding freezes the same way.
_frozen_src="$(t_fn_src "${SMOKE}" _rt_tree_arch_frozen)" || exit 1
_ask() { bash -c '_RT_TREE_ARCH_FROZEN="$1"; shift
  '"${_frozen_src}"'
  if _rt_tree_arch_frozen "$@"; then :; else printf UNFROZEN; fi' _ "$@"; }
t_assert_eq "5" "$(_ask "arm64:/usr/local/llvm-target:X86-64:5" arm64 /usr/local/llvm-target X86-64)"
t_assert_eq "UNFROZEN" "$(_ask "arm64:/usr/local/llvm-target:X86-64:5" riscv64 /usr/local/llvm-target X86-64)" \
  "a freeze is per-arch: the other image must not inherit it"
t_assert_eq "UNFROZEN" "$(_ask "" arm64 /usr/local/llvm-target X86-64)" \
  "with the table empty every builder-arch object is a FAIL again"

t_case "the gate arms that read the count are still wired"
_SMOKE_SRC="$(cat "${SMOKE}")"
t_assert_contains "${_SMOKE_SRC}" 'if [ -n "${_frozen}" ] && [ "${_frozen}" = "${count}" ]; then' \
  "a known count is a note"
t_assert_contains "${_SMOKE_SRC}" "the count MOVED" \
  "a count that moved -- in either direction -- must fail rather than re-freeze itself"

t_summary
