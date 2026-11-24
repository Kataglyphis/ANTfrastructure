#!/usr/bin/env bash
# The isolated web app's .htaccess: isolation, camera, types and caching, and no directive outside Apache's FileInfo class. See docs/docs-sites.md#an-isolated-apps-htaccess
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HTACCESS="$(cd "${TESTS_DIR}/../../webserver/templates" && pwd)/flutter-web-isolated.htaccess"
source "${TESTS_DIR}/htaccess-lines.sh"

t_case "every directive is in Apache's FileInfo override class, the one the host's .htaccess files are proven to use"
t_assert_eq "" "$(_directives | grep -vxE "${HTACCESS_FILEINFO}")" \
  "a directive the host's AllowOverride does not grant turns every page below this file into a 500"

t_case "every directive but a container sits in an <IfModule>, so a missing module drops its block instead of failing the app"
t_assert_eq "" "$(sed -E 's/^[[:space:]]+//' "${HTACCESS}" | awk '
  /^<IfModule / { n++; next } /^<\/IfModule>/ { n--; next } /^(#|$)/ { next }
  n == 0 { print }')"

t_case "the page is cross-origin isolated: COOP same-origin and COEP require-corp on every response"
t_assert_eq 'Header always set Cross-Origin-Opener-Policy "same-origin"' "$(_line 'Cross-Origin-Opener-Policy')"
t_assert_eq 'Header always set Cross-Origin-Embedder-Policy "require-corp"' "$(_line 'Cross-Origin-Embedder-Policy')" \
  "Safari has no credentialless, and without COEP crossOriginIsolated stays false: no wasm threads"
t_assert_eq "mod_headers.c" "$(_guards 'Cross-Origin-Opener-Policy')"

t_case "the camera is allowed for this origin only"
t_assert_eq 'Header always set Permissions-Policy "camera=(self)"' "$(_line 'Permissions-Policy')" \
  "camera=() would refuse getUserMedia; * would hand it to every frame"

t_case "it stands alone: https, HSTS, nosniff and the hidden sync-state file, as the docs site's root has them"
t_assert_eq "RewriteCond %{HTTP:X-Forwarded-Proto} !=https" "$(_line 'X-Forwarded-Proto')"
t_assert_eq "RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]" "$(_line '^RewriteRule ')"
age="$(_line '^Header always set Strict-Transport-Security' | sed -nE 's/.*max-age=([0-9]+).*/\1/p')"
t_assert_eq 1 "$([ "${age:-0}" -ge 31536000 ] && echo 1 || echo 0)" "max-age=${age:-none} is under a year"
t_assert_eq 'Header always set X-Content-Type-Options "nosniff"' "$(_line 'X-Content-Type-Options')"
regex="$(_line '^RedirectMatch 404 ' | awk '{ print $3 }')"
t_assert_eq 1 "$(_matches "${regex}" /app/.ftp-deploy-sync-state.json)"

t_case "wasm and module scripts get the types the browser insists on"
t_assert_eq "AddType application/wasm .wasm" "$(_line '^AddType [^ ]+ \.wasm$')" \
  "WebAssembly.instantiateStreaming rejects a wasm served under any other type"
t_assert_eq "AddType text/javascript .mjs" "$(_line '^AddType [^ ]+ \.mjs$')" \
  "a module script under any non-JavaScript type is refused, and ORT Web ships .mjs"
t_assert_eq "mod_mime.c" "$(_guards '^AddType ')"
t_assert_eq "AddOutputFilterByType DEFLATE application/wasm" "$(_line '^AddOutputFilterByType ')"
t_assert_eq "mod_deflate.c mod_filter.c" "$(_guards '^AddOutputFilterByType ')"

t_case "an unhashed file revalidates; only a versioned path is immutable"
t_assert_eq 'Header set Cache-Control "no-cache"' "$(_line '^Header set Cache-Control "no-cache"$')" \
  "main.dart.wasm keeps its name across builds; a cached one would run against a new main.dart.js"
immutable="$(_line '^Header set Cache-Control .*immutable')"
t_assert_eq 'env=VERSIONED_PATH' "$(printf '%s\n' "${immutable}" | awk '{ print $NF }')" \
  "immutable on every file would pin a returning visitor to an old build for a year"
t_assert_eq 1 "$(sed -E 's/^[[:space:]]+//' "${HTACCESS}" | grep -nE '^Header set Cache-Control' | awk -F: 'NR == 1 { a = $1 } NR == 2 { print ($1 > a) ? 1 : 0 }')" \
  "the env-guarded line must come last, or the plain no-cache overwrites it"
mapfile -t versioned < <(_line '^SetEnvIf Request_URI .*/ort/' ; sed -E 's/^[[:space:]]+//' "${HTACCESS}" | grep -E '^SetEnvIf Request_URI .*/models/')
_versioned() {
  local line
  for line in "${versioned[@]}"; do
    [ "$(_matches "$(printf '%s\n' "${line}" | awk '{ print $3 }' | tr -d '"')" "$1")" = 1 ] && { echo 1; return; }
  done
  echo 0
}
t_assert_eq 1 "$(_versioned /app/ort/1.24.0-3f2a9c1d/ort-wasm-simd-threaded.jspi.wasm)"
t_assert_eq 1 "$(_versioned "/app/models/$(printf 'a%.0s' {1..64})/model.onnx")"
t_assert_eq 0 "$(_versioned /app/main.dart.wasm)"
t_assert_eq 0 "$(_versioned /app/ort/latest/ort.webgpu.mjs)" "a path without a build hash can change under the same name"
t_assert_eq 0 "$(_versioned /app/models/deim/model.onnx)" "a model path without its SHA-256 can change under the same name"
t_assert_eq "mod_setenvif.c" "$(_guards '^SetEnvIf ')"

t_summary
