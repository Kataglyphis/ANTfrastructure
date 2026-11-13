#!/usr/bin/env bash
# Stub alternatives and compiler banners check selection/refusal, not real host links or compiled image behavior.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
fixture="$(t_mktemp -d)"
prefix="${fixture}/source LLVM"
mkdir -p "${prefix}/bin" "${fixture}/bin" || exit 1
export LLVM_ALT_CALLS="${fixture}/calls" LLVM_ALT_FAIL=''
: > "${LLVM_ALT_CALLS}"
cat > "${fixture}/bin/update-alternatives" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LLVM_ALT_CALLS}"
if [ "${LLVM_ALT_FAIL}" = "$1" ]; then exit 47; fi
STUB
chmod +x "${fixture}/bin/update-alternatives"
export PATH="${fixture}/bin:${PATH}"
for name in clang clang++ llvm-ar llvm-ranlib; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "${prefix}/bin/${name}"
  chmod +x "${prefix}/bin/${name}"
done
entry="${TESTS_DIR}/../02-toolchain/register-llvm-alternatives.sh"

t_case "only one explicit absolute source prefix can change alternatives"
t_assert_fails bash "${entry}"
t_assert_fails bash "${entry}" relative
t_assert_fails bash "${entry}" "${prefix}" extra
t_assert_eq '' "$(cat "${LLVM_ALT_CALLS}")"
t_case "every required tool is validated before the first mutation"
for name in clang clang++ llvm-ar llvm-ranlib; do
  mv "${prefix}/bin/${name}" "${prefix}/bin/held"
  t_assert_fails bash "${entry}" "${prefix}"
  t_assert_eq '' "$(cat "${LLVM_ALT_CALLS}")"
  mv "${prefix}/bin/held" "${prefix}/bin/${name}"
done
t_case "every ordinary LLVM alias is manually selected from the supplied tree"
t_assert_ok bash "${entry}" "${prefix}"
expected=''
for name in clang clang++ llvm-ar llvm-ranlib; do
  expected+="--install /usr/bin/${name} ${name} ${prefix}/bin/${name} 120"$'\n'
  expected+="--set ${name} ${prefix}/bin/${name}"$'\n'
done
t_assert_eq "${expected%$'\n'}" "$(cat "${LLVM_ALT_CALLS}")"

t_case "native Docker stage explicitly selects its own source install"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.toolchain")" 'bash /tmp/register-llvm-alternatives.sh "/opt/llvm-target-${TARGETARCH}"'
t_case "alternatives failures keep their raw status"
for action in --install --set; do
  export LLVM_ALT_FAIL="${action}"
  status=0
  bash "${entry}" "${prefix}" >/dev/null 2>&1 || status=$?
  t_assert_eq 47 "${status}"
done
export LLVM_ALT_FAIL=''

_smoke_llvm() {
  bash -c '
    source "$1"
    check_clang_version "$2" 23.1.5 fixture
    smoke_summary
  ' _ "${TESTS_DIR}/../06-packaging/smoke-common.sh" "${fixture}/compiler"
}
cat > "${fixture}/compiler" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${CLANG_BANNER}"
exit "${CLANG_STATUS}"
STUB
chmod +x "${fixture}/compiler"
export CLANG_STATUS=0 CLANG_BANNER='clang version 23.1.5'
t_case "only the complete successful first-line clang version matches"
t_assert_ok _smoke_llvm
export CLANG_BANNER='Ubuntu clang version 23.1.5 (fixture)'
t_assert_ok _smoke_llvm
for banner in '' 'clang version 23.1.6' 'clang version 23.1.50' 'clang version 23.1.5-rc1' 'clang version 23.10.5' $'noise\nclang version 23.1.5' $'clang version 23.1.6\nInstalledDir: /opt/llvm-23.1.5'; do
  export CLANG_BANNER="${banner}"
  t_assert_fails _smoke_llvm
done
export CLANG_BANNER='clang version 23.1.5' CLANG_STATUS=47
t_assert_fails _smoke_llvm

t_case "the real toolchain clang and clang++ checks both reject a wrong patch"
t_source_functions "${TESTS_DIR}/../06-packaging/smoke-toolchain.sh" check_llvm_clang || exit 1
source "${TESTS_DIR}/../06-packaging/smoke-common.sh"
check_dumpmachine() { return 0; }
clang() { printf 'clang version 23.1.6\n'; }
clang++() { printf 'clang version 23.1.6\n'; }
LLVM_RELEASE=23.1.5 check_llvm_clang
t_assert_eq 2 "${FAILURES}"
t_summary
