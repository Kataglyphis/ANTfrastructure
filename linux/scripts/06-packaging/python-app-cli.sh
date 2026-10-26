#!/usr/bin/env bash
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
