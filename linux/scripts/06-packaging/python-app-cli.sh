#!/usr/bin/env bash
# <provider>: the self-test flag a GPU requirement takes; a plugin EP (MIGraphX) is registered, never in onnxruntime's compile-time list.
python_app_provider_requirement() {
  case "$1" in MIGraphX) printf -- '--require-registered-plugin' ;; *) printf -- '--require-available-provider' ;; esac
}

# <provider> [device]: the flags that let AMD's deviceless error stand in for a registration; none where the device exists.
python_app_deviceless_args() {
  if [ "${1:-}" != MIGraphX ] || [ -c "${2:-/dev/kfd}" ]; then return 0; fi
  # AMD's module answers this on a host without a ROCm device. See docs/python-app-bundles.md#linux-gpu-bundles
  printf '%s\n' --deviceless-plugin-error 'HIP failure 100: no ROCm-capable device is detected'
}

# <selftest.py> <root> <provider> <command...>: the app's self-test, with what the provider requires of its report.
python_app_selftest() {
  local selftest="$1" root="$2" provider="$3" line
  shift 3
  local -a args=(--root "${root}")
  if [ -n "${provider}" ]; then
    args+=("$(python_app_provider_requirement "${provider}")" "${provider}")
    if [ "${PYTHON_APP_REQUIRE_ACTIVE_PROVIDER:-false}" = true ]; then args+=(--require-provider "${provider}"); fi
    while IFS= read -r line; do args+=("${line}"); done < <(python_app_deviceless_args "${provider}")
  fi
  # Inside the ROCm image this names the image's module, which the app would register instead of the bundle's.
  (unset ORT_AMDGPU_EP_ROOT; python3 "${selftest}" "${args[@]}" -- "$@")
}

# Both package drivers keep their defaults; this parser only writes options the selected driver accepts.
parse_python_app_args() {
  local mode="$1" variable
  shift
  local -A values=(
    ["--repo-root"]=REPO_ROOT ["--config"]=CONFIG ["--out-dir"]=OUT_DIR ["--work-dir"]=WORK_DIR
  )
  case "${mode}" in
    bundle)
      values["--wheel-dir"]=WHEEL_DIR
      values["--python-version"]=PYTHON_VERSION
      values["--ort-wheel-dir"]=ORT_WHEEL_DIR
      values["--python-runtime"]=PYTHON_RUNTIME ;;
    package)
      values["--bundle"]=BUNDLE
      values["--formats"]=FORMATS ;;
  esac
  while [ "$#" -gt 0 ]; do
    variable="${values[${1:-_unknown}]:-}"
    if [ -n "${variable}" ]; then
      printf -v "${variable}" '%s' "${2:?}"
      shift 2
      continue
    fi
    case "$1" in
      --no-test)
        [ "${mode}" = package ] || { usage >&2; exit 2; }
        variable=RUN_TESTS
        printf -v "${variable}" '%s' false
        shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  return 0
}
