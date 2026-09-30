#!/usr/bin/env bash
set -euo pipefail
# versions.env, the build-arg forwarding and the Dockerfile ARG safety-net defaults must agree.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

# Only the Dockerfiles the forwarding feeds; sync_versions.py's wider set is built by its own scripts.
DOCKERFILES=(base toolchain sdk media android package torch nvidia amd)

echo "=== Version ARG consistency check ==="

# version-forwarding.sh owns the forward-all-except-`# noforward` rule.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/version-forwarding.sh"

echo "Discovered ${#_VERSION_BUILD_ARG_VARS[@]} forwarded variables"

# Load versions.env into associative array (all vars, including noforward).
declare -A _version_values
while IFS='=' read -r key val; do
  [ -n "$key" ] && _version_values["$key"]="$val"
done < <(grep -E '^[A-Z][A-Z0-9_]*=' "${VERSIONS_ENV}" || true)

MISSING=0
for name in "${DOCKERFILES[@]}"; do
  df="linux/Dockerfile.${name}"
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS='=' read -r var val_raw; do
    [ -n "$var" ] || continue
    # ARGs derived from another ARG are computed in the Dockerfile and need no forwarding.
    case "$val_raw" in '${'*) continue ;; esac
    # Only ARGs whose name exists in versions.env are expected to be forwarded.
    [ -n "${_version_values[$var]:-}" ] || continue
    found=0
    for v in "${_VERSION_BUILD_ARG_VARS[@]}"; do
      [ "$v" = "$var" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      echo "WARNING: ${df} ARG '${var}' consumes a versions.env value that is not forwarded (marked # noforward?)"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z_]+=("[^"]*"|\S+)' "$df_path" || true)
done

if [ "$MISSING" -gt 0 ]; then
  echo "WARNING: ${MISSING} ARG(s) may not be auto-forwarded to builds"
  echo "Remove the # noforward marker in versions.env or drop the Dockerfile ARG"
else
  echo "All version ARGs covered by forwarding"
fi

echo ""
echo "=== ARG default value check ==="

VALUE_ERRORS=0
for name in "${DOCKERFILES[@]}"; do
  df="linux/Dockerfile.${name}"
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS='=' read -r var val_raw; do
    [ -z "$var" ] && continue
    env_val="${_version_values[$var]:-}"
    [ -z "$env_val" ] && continue
    # Derived ARGs (default computed from another ARG) have no literal to compare.
    case "$val_raw" in '${'*) continue ;; esac
    # Strip surrounding double quotes from Dockerfile value
    val="${val_raw%\"}"
    val="${val#\"}"
    if [ "$val" != "$env_val" ]; then
      echo "  DRIFT: ${df} ARG ${var}=${val}  ≠  versions.env ${var}=${env_val}"
      VALUE_ERRORS=$((VALUE_ERRORS + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z_]+=("[^"]*"|\S+)' "$df_path" || true)
done

if [ "$VALUE_ERRORS" -gt 0 ]; then
  echo "ERROR: ${VALUE_ERRORS} ARG default(s) differ from versions.env"
  echo "Run: python3 docs/scripts/sync_versions.py --write"
  exit 1
else
  echo "All ARG defaults match versions.env"
fi

echo ""
echo "=== ARG safety-net default presence check ==="
# A default-less versions.env ARG needs a defaulted declaration in the same file, or a plain docker build gets "".
DEFAULTLESS_ERRORS=0
for name in "${DOCKERFILES[@]}"; do
  df="linux/Dockerfile.${name}"
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    [ -n "${_version_values[$var]:-}" ] || continue
    # Exempt: a :?-guarded consumer fails loudly, which beats a default that silently builds the wrong pin.
    case "${df}:${var}" in
      linux/Dockerfile.android:ONNXRUNTIME_VERSION|\
      linux/Dockerfile.android:LITERT_VERSION|\
      linux/Dockerfile.android:IREE_VERSION)
        if grep -rqF "\${${var}:?" "${REPO_ROOT}/linux/scripts/03-media/build/" 2>/dev/null \
           || grep -rqF "\${1:?${var}" "${REPO_ROOT}/linux/scripts/03-media/build/" 2>/dev/null; then
          continue  # :?-guarded consumer exists — deliberate, loud-by-design
        fi
        ;;
    esac
    if ! grep -qP "^\s*ARG\s+${var}=" "$df_path"; then
      echo "  ERROR: ${df} declares ARG ${var} with no default anywhere in the file"
      echo "         (a plain 'docker build' silently gets an empty value; add ARG ${var}=<versions.env value>)"
      DEFAULTLESS_ERRORS=$((DEFAULTLESS_ERRORS + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z][A-Z0-9_]*\s*$' "$df_path" | sort -u || true)
done

if [ "$DEFAULTLESS_ERRORS" -gt 0 ]; then
  echo "ERROR: ${DEFAULTLESS_ERRORS} versions.env-named ARG(s) lack a safety-net default"
  exit 1
else
  echo "All versions.env-named ARGs have a safety-net default in their file"
fi

echo ""
echo "=== Script :- default drift check (advisory) ==="
# Advisory: standalone script defaults may differ on purpose (TVM_REF=main, features off); allow those here.
declare -A SCRIPT_DEFAULT_DRIFT_ALLOW=(
  [TVM_REF]=1 [PYTHON_VERSION]=1
  [FFMPEG_ENABLE_X265]=1 [ORT_ENABLE_WEBGPU]=1 [ORT_WEBGPU_ALLOW_CROSS]=1
  [GENAI_ALLOW_RISCV64]=1
)
DRIFT_WARN=0
while IFS= read -r hit; do
  # := fallbacks drift as silently as :- ones, so both separators are gated.
  file="${hit%%:*}"; match="${hit#*:}"
  var="${match#\$\{}"; var="${var%%:[-=]*}"
  lit="${match#*:[-=]}"; lit="${lit%\}}"
  # Only versions.env variables with a non-empty value are comparable.
  env_val="${_version_values[$var]:-}"
  [ -n "$env_val" ] || continue
  [ -n "${SCRIPT_DEFAULT_DRIFT_ALLOW[$var]:-}" ] && continue
  # Skip non-literal fallbacks: empty, the 'unset' sentinel, expansions and command substitutions.
  case "$lit" in ''|unset|*'$'*|*'('*|*'`'*) continue ;; esac
  env_val="${env_val%\"}"; env_val="${env_val#\"}"   # strip surrounding quotes
  if [ "$lit" != "$env_val" ]; then
    echo "  WARN drift: ${file}  ${match}  ≠  versions.env ${var}=${env_val}"
    DRIFT_WARN=$((DRIFT_WARN + 1))
  fi
done < <(grep -rloP '\$\{[A-Z][A-Z0-9_]*:[-=][^}]*\}' "${REPO_ROOT}/linux/scripts" --include='*.sh' 2>/dev/null \
         | while read -r f; do grep -oP '\$\{[A-Z][A-Z0-9_]*:[-=][^}]*\}' "$f" | sed "s|^|${f}:|"; done)
if [ "$DRIFT_WARN" -gt 0 ]; then
  echo "NOTE: ${DRIFT_WARN} script default(s) differ from versions.env (advisory only)."
  echo "If intentional, add the variable to SCRIPT_DEFAULT_DRIFT_ALLOW in this script."
else
  echo "No script :- default drift detected"
fi

echo ""
echo "=== case-mapped version literal check ==="
# Version literals in case mappings (gcc.sh major->full, common.sh llvm_release_version) that no scan above sees.
LITERAL_ERRORS=0
_gcc_full="${_version_values[GCC_VERSION]:-}"
if [ -n "${_gcc_full}" ]; then
  _gcc_major="${_gcc_full%%.*}"
  if ! grep -qP "^\s*${_gcc_major}\)\s*default_full_version=\"${_gcc_full}\"" \
       "${REPO_ROOT}/linux/scripts/02-toolchain/gcc.sh"; then
    echo "  ERROR: gcc.sh case default for major ${_gcc_major} does not map to ${_gcc_full} (versions.env GCC_VERSION)"
    LITERAL_ERRORS=$((LITERAL_ERRORS + 1))
  fi
fi
_llvm_full="${_version_values[LLVM_RELEASE]:-}"
if [ -n "${_llvm_full}" ]; then
  if ! grep -q "${_llvm_full}" "${REPO_ROOT}/linux/scripts/01-core/common.sh"; then
    echo "  ERROR: common.sh llvm_release_version mapping does not contain ${_llvm_full} (versions.env LLVM_RELEASE)"
    LITERAL_ERRORS=$((LITERAL_ERRORS + 1))
  fi
fi
if [ "${LITERAL_ERRORS}" -gt 0 ]; then
  echo "ERROR: ${LITERAL_ERRORS} case-mapped version literal(s) drifted from versions.env"
  exit 1
else
  echo "Case-mapped version literals match versions.env"
fi

echo ""
echo "=== GCC toolchain default literal check ==="
# Fatal: RUNs without common.sh use the inline GCC_VERSION/GCC_WANTED literal as the value, so each must match.
GCC_LITERAL_ERRORS=0
_gcc_env_full="${_version_values[GCC_VERSION]:-}"
_gcc_env_full="${_gcc_env_full%\"}"; _gcc_env_full="${_gcc_env_full#\"}"
if [ -z "${_gcc_env_full}" ]; then
  echo "  ERROR: versions.env defines no GCC_VERSION - cannot pin the toolchain literals"
  GCC_LITERAL_ERRORS=1
else
  _gcc_env_major="${_gcc_env_full%%.*}"
  _gcc_sites=0
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    _loc="${hit%%:\$\{*}"            # "<path>:<line>"
    _expr="\${${hit#*:\$\{}"         # the matched expansion, re-prefixed
    _var="${_expr#\$\{}"; _var="${_var%%:[-=]*}"
    _lit="${_expr#*:[-=]}"; _lit="${_lit%\}}"
    case "${_var}" in
      GCC_VERSION) _want="${_gcc_env_full}" ;;
      GCC_WANTED)  _want="${_gcc_env_major}" ;;
      *) continue ;;
    esac
    _gcc_sites=$((_gcc_sites + 1))
    if [ "${_lit}" != "${_want}" ]; then
      echo "  ERROR: ${_loc#"${REPO_ROOT}/"}  ${_expr}  ≠  expected ${_var} default ${_want}"
      GCC_LITERAL_ERRORS=$((GCC_LITERAL_ERRORS + 1))
    fi
  done < <(grep -rnoP '\$\{(GCC_VERSION|GCC_WANTED):[-=][^{}$]+\}' \
             "${REPO_ROOT}/linux" 2>/dev/null \
           | grep -v '/verify-arg-consistency\.sh:' || true)
  # A scan that finds almost nothing must not pass: the pattern has stopped matching the tree.
  if [ "${_gcc_sites}" -lt 10 ]; then
    echo "[ERROR] GCC literal gate scanned only ${_gcc_sites} site(s) (expected >=10) — the scan pattern no longer matches the tree; fix the pattern rather than trusting this pass" >&2
    GCC_LITERAL_ERRORS=$((GCC_LITERAL_ERRORS + 1))
  fi
  echo "Scanned ${_gcc_sites} inline GCC version default(s) under linux/"
fi
if [ "${GCC_LITERAL_ERRORS}" -gt 0 ]; then
  echo "ERROR: ${GCC_LITERAL_ERRORS} inline GCC toolchain default(s) drifted from versions.env"
  echo "Update every listed site to versions.env GCC_VERSION=${_gcc_env_full} (they all name /opt/gcc-<ver>)"
  exit 1
else
  echo "All inline GCC toolchain defaults match versions.env"
fi

echo ""
echo "=== hand-forward of auto-forwarded ARG check ==="
# A literal --build-arg for an auto-forwarded variable is a second channel that drifts; tests/ quote it, so skip them.
HANDFWD_ERRORS=0
_vars_alt="$(IFS='|'; printf '%s' "${_VERSION_BUILD_ARG_VARS[*]}")"
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  echo "  ERROR: hand-forward duplicates auto-forwarding: ${hit}"
  HANDFWD_ERRORS=$((HANDFWD_ERRORS + 1))
done < <(grep -rnP --include='*.sh' --exclude-dir=tests \
           -e "--build-arg\s+\"?(${_vars_alt})=" "${REPO_ROOT}/linux/scripts" 2>/dev/null || true)
if [ "$HANDFWD_ERRORS" -gt 0 ]; then
  echo "ERROR: ${HANDFWD_ERRORS} literal --build-arg line(s) hand-forward an auto-forwarded versions.env variable"
  echo "Delete the hand-forward; append_version_build_args already forwards it"
  exit 1
else
  echo "No hand-forwards of auto-forwarded versions.env variables"
fi

echo "DONE: version ARG consistency check"
