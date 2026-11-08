#!/usr/bin/env bash
# The one probe for ORT's plugin entry points (plugin builds and the media verify stage; sets no shell options): never grep -q, which closes the pipe at the first match so readelf dies of SIGPIPE under pipefail on a 4000-symbol module.
plugin_ep_module_has_export() {
  readelf --dyn-syms -W "$1" 2>/dev/null | grep -E " $2(@@[A-Za-z0-9_.]+)?$" >/dev/null
}
