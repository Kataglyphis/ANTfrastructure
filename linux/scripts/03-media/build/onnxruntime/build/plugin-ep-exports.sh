#!/usr/bin/env bash
# The one probe for ORT's two plugin entry points, shared by the plugin builds and the media verify stage; sets no shell options.
# No grep -q: it closes the pipe at the first match, readelf dies of SIGPIPE, and pipefail fails a module with thousands of symbols (the TensorRT plugin).
plugin_ep_module_has_export() {
  readelf --dyn-syms -W "$1" 2>/dev/null | grep -E " $2(@@[A-Za-z0-9_.]+)?$" >/dev/null
}
