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
_FAM_SRC="$(t_fn_src "${MAT}" _is_llvm_family)" || exit 1
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
    '"${_FAM_SRC}"'
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

# ── _is_llvm_family: the one owner of "the prefix carries this itself" ──────
t_case "_is_llvm_family covers what the prefix must own and nothing else"
_fam() { bash -c "${_FAM_SRC}"$'\n''if _is_llvm_family "$1"; then echo OWN; else echo BORROW; fi' _ "$1"; }
t_assert_eq "OWN" "$(_fam libLLVM.so.23.1)"
t_assert_eq "OWN" "$(_fam libclang-23.so.23)"
t_assert_eq "OWN" "$(_fam liblldb-23.so.1)" \
  "the builder ldcache had it and the runtime image never did: 3 of the shipped prefix's 142 binaries cannot start, all three on this soname"
t_assert_eq "BORROW" "$(_fam libc++.so.1)" \
  "a second libc++ in a prefix that ld.so.conf publishes FIRST would shadow the base image's for every consumer"
t_assert_eq "BORROW" "$(_fam libstdc++.so.6)"
t_assert_eq "BORROW" "$(_fam libc++abi.so.1)"

# ── _llvm_target_repair_links over the measured Debian layout ───────────────
# The amd64 prefix is an apt tree: `ls -la /usr/lib/llvm-23/lib` links the dev
# entries at ../../x86_64-linux-gnu RELATIVE TO ITS OWN LOCATION, so `cp -a` to
# /opt/llvm-target breaks 19 of them in the sdk stage; ldconfig later deletes the
# 7 that look like sonames and 12 reach the shipped image.
_REPAIR_SRC="$(t_fn_src "${MAT}" _llvm_target_repair_links)" || exit 1
_repair() {
  bash -c "${_FAM_SRC}"$'\n'"${_REPAIR_SRC}"$'\n''_llvm_target_repair_links "$1" "$2"' _ "$1" "$2" 2>&1
}

# root/ is the ORIGINAL prefix (every link resolves there); dest/llvm-target is
# the copy at a different depth, which is what breaks them.
_mk_apt_fixture() {
  _T="$(mktemp -d)"
  mkdir -p "${_T}/root/lib/python3.14/site-packages/lldb/native" "${_T}/root/include" \
           "${_T}/multiarch" "${_T}/include/llvm-23/llvm"
  local _f
  for _f in libclang-23.so.23 liblldb-23.so.1 libLLVM.so.23.1 libc++.a libc++.modules.json libc++.so.1.0; do
    printf 'real %s\n' "${_f}" > "${_T}/multiarch/${_f}"
  done
  : > "${_T}/include/llvm-23/llvm/IR.h"
  ( cd "${_T}/root/lib" || exit 1
    ln -s ../../multiarch/libclang-23.so.23 libclang-23.so
    ln -s ../../multiarch/libclang-23.so.23 libclang.so
    ln -s libclang-23.so libclang-23.1.0.so
    ln -s ../../multiarch/libc++.so.1.0 libc++.so.1.0
    ln -s libc++.so.1.0 libc++.so.1
    ln -s libc++.so.1 libc++.so
    ln -s ../../multiarch/libc++.a libc++.a
    ln -s ../../multiarch/libc++.modules.json libc++.modules.json
    ln -s ../../multiarch/liblldb-23.so.1 liblldb-23.so.1
    ln -s ../../multiarch/libLLVM.so.23.1 libLLVM.so.23.1
    ln -s ../../../../../../multiarch/liblldb-23.so.1 python3.14/site-packages/lldb/native/_lldb.cpython-314.so
    cd ../include || exit 1
    ln -s ../../include/llvm-23/llvm llvm )
  mkdir -p "${_T}/dest"; cp -a "${_T}/root" "${_T}/dest/llvm-target"
  _P="${_T}/dest/llvm-target"
}

t_case "the copied prefix is the thing that breaks -- the original resolves"
_mk_apt_fixture
t_assert_eq "0" "$(find "${_T}/root" -xtype l | wc -l)" "every link resolves where the tree was installed"
t_assert_eq "12" "$(find "${_P}" -xtype l | wc -l)" "cp -a to another depth breaks every one of them"

t_case "after the repair nothing under the prefix resolves to nothing"
_repair "${_P}" "${_T}/root" >/dev/null
t_assert_eq "0" "$(find "${_P}" -xtype l | wc -l)"

t_case "the three libclang dev links are re-pointed INSIDE the prefix"
t_assert_eq "libclang-23.so.23" "$(readlink "${_P}/lib/libclang.so")" \
  "an absolute or outward target is exactly the defect; clang.cindex opens this name"
t_assert_eq "libclang-23.so.23" "$(readlink "${_P}/lib/libclang-23.so")"
t_assert_eq "libclang-23.so.23" "$(readlink "${_P}/lib/libclang-23.1.0.so")" \
  "a link to a link is flattened onto the real file"
t_assert_ok test -f "${_P}/lib/libclang-23.so.23"

t_case "an LLVM-family soname the prefix does not have is materialised"
t_assert_ok test -f "${_P}/lib/liblldb-23.so.1"

# The Debian multiarch dev shape: lib/libX.so.N -> ../../<triplet>/libX.so.N. The
# target's basename IS the link's own name, so the repair copies the real file
# exactly onto the link's path -- and relinking there would replace the file it
# just wrote with a symlink to itself. `find -xtype l` calls that dangling, which
# is how it took the whole sdk stage down on 2026-09-05 (libclang-cpp.so.23.1).
t_case "a link whose target carries its OWN name ends as the file, not a self-link"
t_assert_eq "" "$(readlink "${_P}/lib/libLLVM.so.23.1" || true)" \
  "anything here means the real file was overwritten by a link to itself"
t_assert_eq "real libLLVM.so.23.1" "$(cat "${_P}/lib/libLLVM.so.23.1" 2>/dev/null || true)" \
  "nothing else in the fixture names this basename, so nothing heals it after the fact"
t_assert_eq "0" "$(find "${_P}/lib" -name libLLVM.so.23.1 -xtype l | wc -l)" \
  "this is the exact find the script's own final assertion runs"
t_assert_eq "real liblldb-23.so.1" "$(cat "${_P}/lib/liblldb-23.so.1")"

t_case "a deep link is re-pointed with a path that resolves from ITS OWN dir"
_NAT="${_P}/lib/python3.14/site-packages/lldb/native/_lldb.cpython-314.so"
t_assert_eq "../../../../liblldb-23.so.1" "$(readlink "${_NAT}")" \
  "a bare basename would dangle four levels down; an absolute /opt path would dangle after the COPY"
t_assert_ok test -f "${_NAT}"

t_case "a dev entry naming a package the prefix does not carry is DROPPED"
t_assert_eq "" "$(find "${_P}/lib" -maxdepth 1 -name 'libc++*' -printf '%f\n')" \
  "libc++.a/.modules.json/.so name libc++-23-dev and libc++1 -- materialising them puts a second libc++ ahead of the base image's on the loader path"
t_assert_ok test -f "${_T}/multiarch/libc++.a"
t_assert_eq "real libc++.a" "$(cat "${_T}/multiarch/libc++.a")" "dropping a link must not touch the tree it named"

t_case "a link naming a DIRECTORY is materialised in place"
t_assert_ok test -f "${_P}/include/llvm/IR.h"
t_assert_eq "" "$(readlink "${_P}/include/llvm")" "it is a directory now, not a link"
rm -rf "${_T}"

t_case "the repair is idempotent and safe with the prefix as its own root"
_mk_apt_fixture
_repair "${_P}" "${_T}/root" >/dev/null
_before="$(cd "${_P}" && find . | LC_ALL=C sort)"
_repair "${_P}" "${_P}" >/dev/null
t_assert_eq "${_before}" "$(cd "${_P}" && find . | LC_ALL=C sort)" \
  "the foreign branch passes the prefix as its own root -- measured 0 dangling there, so it must be a no-op"
rm -rf "${_T}"

t_case "a link the repair cannot resolve anywhere is removed, not left"
_mk_apt_fixture
ln -s /nowhere/at/all "${_P}/lib/libGONE.so"
ln -s /nowhere/at/all "${_T}/root/lib/libGONE.so"
_repair "${_P}" "${_T}/root" >/dev/null
t_assert_eq "0" "$(find "${_P}" -xtype l | wc -l)"
t_assert_fails test -e "${_P}/lib/libGONE.so"
rm -rf "${_T}"

t_case "a dangling link the repair CANNOT reach fails the sdk stage"
# The one path that survives the loop: a materialised directory that brings a
# broken link of its own. A stage that ships it is the whole defect returning.
_mk_apt_fixture
ln -s ../../nowhere "${_T}/include/llvm-23/llvm/stale.h"
_out="$(_repair "${_P}" "${_T}/root")" && _rc=0 || _rc=$?
t_assert_eq 1 "${_rc}" "silently shipping it is what put twelve of these in the image"
t_assert_contains "${_out}" "resolve to nothing"
rm -rf "${_T}"

t_case "the sdk stage repairs BEFORE it fills, on every arch"
_MAT_SRC_EARLY="$(cat "${MAT}")"
t_assert_contains "${_MAT_SRC_EARLY}" '_llvm_target_repair_links /opt/llvm-target "${_hostllvm}"' \
  "amd64 resolves against the apt tree it was copied from -- the copy itself is where the links break"
t_assert_contains "${_MAT_SRC_EARLY}" "_llvm_target_repair_links /opt/llvm-target /opt/llvm-target" \
  "the source-built foreign prefixes measured 0 dangling; the call keeps that true rather than assuming it"
_repair_line="$(printf '%s\n' "${_MAT_SRC_EARLY}" | grep -n -e '_llvm_target_repair_links /opt/llvm-target "' | cut -d: -f1)"
_fill_line="$(printf '%s\n' "${_MAT_SRC_EARLY}" | grep -n -e '_llvm_target_fill_needed /opt/llvm-target' | cut -d: -f1)"
t_assert_ok test "${_repair_line}" -lt "${_fill_line}"

t_case "one family owner, three callers"
t_assert_eq 3 "$(printf '%s\n' "${_MAT_SRC_EARLY}" | grep -c -e '_is_llvm_family ')" \
  "the fill, the repair and the self-containment walk must not each carry their own pattern"
t_assert_eq "" "$(printf '%s\n' "${_MAT_SRC_EARLY}" | grep -e 'libLLVM\*|libclang\*)')" \
  "an inline copy of the family pattern is how liblldb stayed outside it"

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
