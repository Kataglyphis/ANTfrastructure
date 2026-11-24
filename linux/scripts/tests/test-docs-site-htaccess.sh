#!/usr/bin/env bash
# The docs sites' .htaccess and 404 page: what the hub promises, and no directive outside Apache's FileInfo class. See docs/docs-sites.md#the-sites-htaccess
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
TEMPLATES="$(cd "${TESTS_DIR}/../../webserver/templates" && pwd)"
# shellcheck disable=SC2034  # read by htaccess-lines.sh
HTACCESS="${TEMPLATES}/docs-site.htaccess"
PAGE_404="${TEMPLATES}/docs-site-404.html"
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

source "${TESTS_DIR}/htaccess-lines.sh"

t_case "every directive is in Apache's FileInfo override class, the one the host's .htaccess files are proven to use"
t_assert_eq "" "$(_directives | grep -vxE "${HTACCESS_FILEINFO}")" \
  "a directive the host's AllowOverride does not grant turns every page of the site into a 500"

t_case "plain http goes to https, permanently, and a TLS proxy cannot loop it"
t_assert_eq "RewriteEngine On" "$(_line '^RewriteEngine ')"
t_assert_eq "RewriteCond %{HTTPS} !=on" "$(_line '^RewriteCond %\{HTTPS\}')"
t_assert_eq "RewriteCond %{HTTP:X-Forwarded-Proto} !=https" "$(_line 'X-Forwarded-Proto')" \
  "behind a proxy that ends TLS, HTTPS is off on every request and the redirect would never stop"
t_assert_eq "RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]" "$(_line '^RewriteRule ')"

t_case "HSTS for at least a year, and nosniff, on every response"
age="$(_line '^Header always set Strict-Transport-Security' | sed -nE 's/.*max-age=([0-9]+).*/\1/p')"
t_assert_eq 1 "$([ "${age:-0}" -ge 31536000 ] && echo 1 || echo 0)" "max-age=${age:-none} is under a year"
t_assert_eq 'Header always set X-Content-Type-Options "nosniff"' "$(_line 'X-Content-Type-Options')"

t_case "the FTP library's sync-state file is not served, at the root or below"
rule="$(_line '^RedirectMatch ')"
t_assert_eq "404" "$(printf '%s\n' "${rule}" | awk '{ print $2 }')" "denied as absent, so the 404 page shows"
regex="$(printf '%s\n' "${rule}" | awk '{ print $3 }')"
t_assert_eq 1 "$(_matches "${regex}" /.ftp-deploy-sync-state.json)"
t_assert_eq 1 "$(_matches "${regex}" /sub/.ftp-deploy-sync-state.json)" "a server-dir below the docroot keeps its own state file"
t_assert_eq 0 "$(_matches "${regex}" /index.html)"
t_assert_eq 0 "$(_matches "${regex}" /notes.ftp-deploy-sync-state.json)"

t_case "the WebGPU demo's wasm and glTF files get their registered types"
t_assert_eq "AddType application/wasm .wasm" "$(_line '^AddType [^ ]+ \.wasm$')" \
  "WebAssembly.instantiateStreaming rejects a wasm served under any other type"
t_assert_eq "AddType model/gltf-binary .glb" "$(_line '^AddType [^ ]+ \.glb$')"
t_assert_eq "AddType model/gltf+json .gltf" "$(_line '^AddType [^ ]+ \.gltf$')"
t_assert_eq "mod_mime.c" "$(_guards '^AddType ')"

t_case "those types are gzipped, behind both modules the directive needs"
types="$(_line '^AddOutputFilterByType DEFLATE ' | cut -d' ' -f3- | tr ' ' '\n' | sort | paste -sd' ' -)"
t_assert_eq "application/wasm model/gltf+json model/gltf-binary" "${types}" \
  "the host gzips text itself, never these; a 61 MB scene goes out at 30 MB"
t_assert_eq "mod_deflate.c mod_filter.c" "$(_guards '^AddOutputFilterByType ')" \
  "mod_filter owns the directive and mod_deflate the filter; either one missing must drop the line, not fail the site"

t_case "a 404 page the ErrorDocument names, whole and with links that resolve"
t_assert_eq "ErrorDocument 404 /404.html" "$(_line '^ErrorDocument ')"
t_assert_eq 1 "$(grep -ci '^<!DOCTYPE html>' "${PAGE_404}")"
mkdir -p "${_tmp}/site"
printf '<!DOCTYPE html>\n<html><body><a href="404.html">x</a></body></html>\n' > "${_tmp}/site/index.html"
cp "${PAGE_404}" "${_tmp}/site/404.html"
t_assert_ok "${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/../verify_site_links.py" "${_tmp}/site"

t_summary
