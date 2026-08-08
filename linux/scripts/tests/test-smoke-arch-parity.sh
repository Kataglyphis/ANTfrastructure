#!/usr/bin/env bash
# Parity suite: smoke-common.sh's inline arch-map FALLBACKS must agree with
# the canonical 01-core maps. Every in-image smoke sources smoke-common; when
# the canonical modules are absent it falls back to its bundled maps — this
# file has already produced two silent-skip bugs (see its own comments), and
# nothing asserted fallback/canonical parity until now. Add an arch to
# platform.sh without updating smoke-common and this suite goes red instead
# of the smokes silently returning 1.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

SMOKE_COMMON="${TESTS_DIR}/../06-packaging/smoke-common.sh"
CORE="${TESTS_DIR}/../01-core"

# Run a smoke-common function in a CLEAN bash where the canonical 01-core
# functions do not exist — forcing the fallback branch.
_fallback() {
  bash -c "source '${SMOKE_COMMON}' 2>/dev/null; $1" 2>/dev/null
}

# Canonical values from the real modules in THIS shell.
source "${CORE}/platform.sh"
source "${CORE}/arch-mapping.sh"

for _arch in amd64 arm64 riscv64; do
  t_case "uname-name parity for ${_arch}"
  t_assert_eq "$(arch_uname_name_for "${_arch}")" \
              "$(_fallback "smoke_uname_name ${_arch}")" \
              "smoke-common fallback diverged from platform.sh"

  t_case "ELF-machine parity for ${_arch}"
  # smoke_elf_machine_grep is a GREP PATTERN; canonical arch_to_elf_machine is
  # the full readelf string — parity means the pattern MATCHES the canonical.
  t_assert_contains "$(arch_to_elf_machine "${_arch}")" \
              "$(_fallback "smoke_elf_machine_grep ${_arch}")" \
              "smoke-common grep pattern no longer matches the canonical ELF machine string"
done

t_case "host-arch normalization parity"
for _m in x86_64 aarch64 riscv64; do
  t_assert_eq "$(arch_normalize "${_m}")" "$(_fallback "smoke_host_arch ${_m}")"
done

t_case "smoke_arch_words splits under strict IFS (the historical bug class)"
_count="$(_fallback "IFS=\$'\n\t'; set -- \$(smoke_arch_words 'amd64,arm64,riscv64'); echo \$#")"
t_assert_eq "3" "${_count}" "comma list must yield 3 words under IFS=\$'\\n\\t'"

t_case "arch_list_to_words splits under strict IFS too"
_count="$(bash -c "source '${CORE}/platform.sh'; source '${CORE}/build-helpers.sh'; IFS=\$'\n\t'; set -- \$(arch_list_to_words 'amd64,arm64,riscv64'); echo \$#" 2>/dev/null)"
t_assert_eq "3" "${_count}" "the 16 latent for-loop sites are safe only if this splits"

t_summary
