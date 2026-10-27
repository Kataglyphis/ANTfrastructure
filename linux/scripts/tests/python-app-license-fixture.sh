#!/usr/bin/env bash
# A small consumer project shared by bundle and installer license tests.
python_app_license_fixture() {
  local repo="$1" bundle="$2"
  mkdir -p "${repo}/packaging" "${bundle}/bin"
  printf 'Original project terms\n' > "${repo}/LICENSE"
  cp "${repo}/LICENSE" "${bundle}/LICENSE"
  cat > "${repo}/packaging/app.json" <<'JSON'
{"id":"demo","name":"Demo","description":"Fixture","distribution":"demo","data_env":"DATA_DIR","data_dir":"data","license_file":"LICENSE","extras":[],"scripts":["demo"],"self_test":["demo"]}
JSON
}
