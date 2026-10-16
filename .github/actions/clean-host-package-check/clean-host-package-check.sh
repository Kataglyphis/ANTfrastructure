#!/usr/bin/env bash
# clean-host-package-check.sh: installs and starts a Linux package on a bare runner, where none of the image's libraries are.
set -euo pipefail

dir="${PACKAGES_DIR:?}"
failures=0

# A glob matching two packages would test one of them silently, so exactly one is required.
one() {
  local count
  count="$(find "${dir}" -maxdepth 1 -name "$1" | wc -l)"
  [ "${count}" -eq 1 ] || { printf 'ERROR: %s matches %s files in %s, not one\n' "$1" "${count}" "${dir}" >&2; ls -la "${dir}" >&2; exit 1; }
  find "${dir}" -maxdepth 1 -name "$1"
}

# tr: a file opening with NUL bytes would make the substitution warn for every one of them.
is_elf() { [ -f "$1" ] && [ "$(head -c 4 -- "$1" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ]; }

# A missing library and a missing symbol version both print "not found"; the image hides either.
scan_elves() {
  local f out
  while IFS= read -r f; do
    is_elf "${f}" || continue
    out="$(ldd "${f}" 2>&1 || true)"
    if grep -q 'not found' <<< "${out}"; then
      printf '::error file=%s::unresolved on a clean host\n' "${f}"
      grep 'not found' <<< "${out}" | sed 's/^/    /'
      failures=$((failures + 1))
    fi
  done
}

run() {
  printf '+ %s\n' "$1"
  # LD_BIND_NOW: an undefined symbol fails at start, not on the first call that needs it.
  if ! (cd "${2:-.}" && LD_BIND_NOW=1 bash -c "$1"); then
    printf '::error::%s failed on a clean host\n' "$1"
    failures=$((failures + 1))
  fi
}

printf 'Clean host: %s, glibc %s\n' "$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)" \
  "$(ldd --version | head -1 | awk '{print $NF}')"

if [ -n "${DEB_GLOB:-}" ]; then
  deb="$(one "${DEB_GLOB}")"
  sudo apt-get update -qq
  # The package's Depends are what a user's apt resolves; nothing else is installed for it.
  # shellcheck disable=SC2086  # APT_PACKAGES is a word list on purpose
  sudo apt-get install -y --no-install-recommends "$(realpath "${deb}")" ${APT_PACKAGES:-}
  pkg="$(dpkg-deb -f "${deb}" Package)"
  echo "== ${pkg}: every installed ELF"
  scan_elves < <(dpkg -L "${pkg}")
  [ -z "${DEB_COMMAND:-}" ] || run "${DEB_COMMAND}"
elif [ -n "${APT_PACKAGES:-}" ]; then
  sudo apt-get update -qq
  # shellcheck disable=SC2086
  sudo apt-get install -y --no-install-recommends ${APT_PACKAGES}
fi

if [ -n "${TARBALL_GLOB:-}" ]; then
  tarball="$(one "${TARBALL_GLOB}")"
  root="$(mktemp -d)"
  tar -xzf "${tarball}" -C "${root}"
  # CPack nests everything under one top directory; a flat tarball has none.
  mapfile -t tops < <(find "${root}" -mindepth 1 -maxdepth 1)
  [ "${#tops[@]}" -eq 1 ] && [ -d "${tops[0]}" ] && root="${tops[0]}"
  echo "== $(basename "${tarball}"): every ELF, unpacked anywhere"
  scan_elves < <(find "${root}" -type f)
  [ -z "${TARBALL_COMMAND:-}" ] || run "${TARBALL_COMMAND}" "${root}"
fi

if [ -n "${APPIMAGE_GLOB:-}" ]; then
  APPIMAGE="$(realpath "$(one "${APPIMAGE_GLOB}")")"
  [ -x "${APPIMAGE}" ] || chmod +x "${APPIMAGE}"
  echo "== $(basename "${APPIMAGE}")"
  # Extract-and-run needs no FUSE, which a runner lacks.
  export APPIMAGE APPIMAGE_EXTRACT_AND_RUN=1
  run "${APPIMAGE_COMMAND:?appimage-command is required with appimage}"
fi

if [ "${failures}" -ne 0 ]; then
  printf 'ERROR: %d check(s) failed on a clean host\n' "${failures}" >&2
  exit 1
fi
echo "Every package installs and starts on a clean host."
