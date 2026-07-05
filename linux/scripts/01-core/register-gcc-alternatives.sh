#!/usr/bin/env bash
set -euo pipefail

# register-gcc-alternatives.sh
#
# Re-registers gcc/g++ (and the cc/c++ aliases) as the system default
# alternatives, pointing at the custom /opt/gcc-${GCC_VERSION} toolchain. Needed
# after install-deps resets the alternatives to the distro compiler. Mirrors the
# 02-toolchain/register-llvm-alternatives.sh precedent; extracted verbatim from
# the inline RUN in linux/Dockerfile.media so it can be shellcheck'd and reused.
#
# Environment:
#   GCC_VERSION   e.g. "16.1.0" (custom toolchain under /opt/gcc-${GCC_VERSION})

# name:bin pairs — cc/c++ point at gcc/g++; install (prio 150) then set each.
for _pair in "gcc:gcc" "g++:g++" "cc:gcc" "c++:g++"; do
  _name="${_pair%%:*}"
  _bin="${_pair#*:}"
  update-alternatives --install "/usr/bin/${_name}" "${_name}" "/opt/gcc-${GCC_VERSION}/bin/${_bin}" 150
  update-alternatives --set "${_name}" "/opt/gcc-${GCC_VERSION}/bin/${_bin}"
done

cc --version 2>&1 | head -1
c++ --version 2>&1 | head -1
