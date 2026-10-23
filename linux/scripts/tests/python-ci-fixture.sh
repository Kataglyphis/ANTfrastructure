#!/usr/bin/env bash
# Copied Python CI drivers carry the interpreter probe required by their uv module.
python_ci_fixture() {
  t_python_ci_fixture "$1" "$2" 01-core/python-probe.sh "${@:3}"
}
