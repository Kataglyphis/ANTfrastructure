#!/usr/bin/env bash
# Copied Python CI drivers carry the companions required by their uv module.
python_ci_fixture() {
  t_python_ci_fixture "$1" "$2" 01-core/python-probe.sh 01-core/verified-script-install.sh "${@:3}"
}
