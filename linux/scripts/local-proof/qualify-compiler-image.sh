#!/usr/bin/env bash
# Fresh-image defaults must work without the diagnostic replay's environment corrections.
set -euo pipefail
gcc_pin="$1"
llvm_pin="$2"
native_prefix="$3"
mode="${4:-default}"
case "$mode" in
  default) stem="" ;;
  login) stem="login-" ;;
  *) exit 2 ;;
esac
python3 /opt/scripts/packaging/probe-compiler-defaults.py \
  --llvm-version "$llvm_pin" --native-llvm-prefix "$native_prefix" > "/evidence/${stem}native.json"
python3 /opt/scripts/packaging/probe-compiler-defaults.py \
  --gcc-version "$gcc_pin" --llvm-version "$llvm_pin" > "/evidence/${stem}defaults.json"
python3 /plain-load.py libLLVM.so.23.1 "$native_prefix" "/evidence/${stem}maps.txt" > "/evidence/${stem}loaded.json"
library_path="$(python3 -c 'import json,sys; from pathlib import Path; row=json.loads(Path(sys.argv[1]).read_text()); assert len(row["libraries"])==1; print(row["libraries"][0]["source"])' "/evidence/${stem}native.json")"
sha256sum -- "$library_path" > "/evidence/${stem}source-library-sha256.txt"
sha256sum /opt/scripts/packaging/probe-compiler-defaults.py \
  /opt/scripts/packaging/llvm-loader-path.sh > "/evidence/${stem}baked-script-sha256.txt"
cat /etc/ld.so.conf.d/000-llvm-native.conf > "/evidence/${stem}native-conf.txt"
python3 -c 'import json,os; print(json.dumps({key:os.environ.get(key) for key in ("PATH","LD_LIBRARY_PATH","LD_PRELOAD","CC","CXX")}))' > "/evidence/${stem}environment.json"
if [ "$mode" = default ]; then
  bash -lc 'exec bash /qualify.sh "$@"' compiler-login-qualification "$gcc_pin" "$llvm_pin" "$native_prefix" login
fi
exit 0
