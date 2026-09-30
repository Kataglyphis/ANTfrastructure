#!/usr/bin/env bash
set -euo pipefail

# Re-points gcc/g++/cc/c++ at /opt/gcc-${GCC_VERSION}; install-deps resets them to the distro compiler.

# name:bin pairs — cc/c++ point at gcc/g++; install (prio 150) then set each.
for _pair in "gcc:gcc" "g++:g++" "cc:gcc" "c++:g++"; do
  _name="${_pair%%:*}"
  _bin="${_pair#*:}"
  update-alternatives --install "/usr/bin/${_name}" "${_name}" "/opt/gcc-${GCC_VERSION}/bin/${_bin}" 150
  update-alternatives --set "${_name}" "/opt/gcc-${GCC_VERSION}/bin/${_bin}"
done

cc --version 2>&1 | head -1
c++ --version 2>&1 | head -1
