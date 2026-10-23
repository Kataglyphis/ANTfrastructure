#!/usr/bin/env bash
# Integration smoke test for a built Flutter web app, via curl; usage: flutter_integration_smoke_test.sh [base_url]

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
# Hosts the page's CSP must name; none by default, since the family's builds serve their own engine and fonts.
REQUIRED_CSP_HOSTS="${REQUIRED_CSP_HOSTS:-}"
CHECK_LOADING_SHELL="${CHECK_LOADING_SHELL:-1}"
CHECK_LOCAL_ENGINE="${CHECK_LOCAL_ENGINE:-1}"
CHECK_FALLBACK_FONTS="${CHECK_FALLBACK_FONTS:-0}"
FALLBACK_FONTS_LOCK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/05-frameworks/flutter" && pwd)/fallback-fonts.lock"

# expect_wasm <path>: served as application/wasm, or the browser refuses to compile it.
expect_wasm() {
  local mime
  mime=$(curl -s -I "$BASE_URL/$1" | grep -i "content-type:" | tr -d '\r' || true)
  if printf '%s' "$mime" | grep -q "application/wasm"; then
    echo "PASS: $1 served as application/wasm"
  else
    echo "FAIL: $1 not served as application/wasm: $mime"
    exit 1
  fi
}

expect_http_200() {
  local path="$1" label="$2" status
  status="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/$path" || true)"
  if [ "$status" != 200 ]; then
    echo "FAIL: $label returned HTTP $status"
    exit 1
  fi
  return 0
}

download_size_exceeds() {
  local -n result="$3"
  result="$(curl -s -o /dev/null -w "%{size_download}" "$BASE_URL/$1")" || exit "$?"
  if [ "$result" -gt "$2" ]; then return 0; fi
  return 1
}

echo "=== Integration Smoke Test ==="
echo "Target: $BASE_URL"
echo ""

# `|| true` on the probes, or set -e kills the script before its FAIL diagnostics print.
echo "--- Testing: index.html loads ---"
expect_http_200 '' index.html
echo "PASS: index.html HTTP 200"

echo "--- Testing: main.dart.wasm MIME type ---"
expect_wasm main.dart.wasm

echo "--- Testing: main.dart.js exists ---"
if download_size_exceeds main.dart.js 10000 JS_SIZE; then
  echo "PASS: main.dart.js served ($JS_SIZE bytes)"
else
  echo "FAIL: main.dart.js too small or missing ($JS_SIZE bytes)"
  exit 1
fi

echo "--- Testing: flutter_bootstrap.js exists ---"
if download_size_exceeds flutter_bootstrap.js 100 BOOT_SIZE; then
  echo "PASS: flutter_bootstrap.js served ($BOOT_SIZE bytes)"
else
  echo "FAIL: flutter_bootstrap.js missing"
  exit 1
fi

echo "--- Testing: manifest.json ---"
MANIFEST=$(curl -s "$BASE_URL/manifest.json")
if printf '%s' "$MANIFEST" | grep -q '"name"'; then
  echo "PASS: manifest.json valid"
else
  echo "FAIL: manifest.json invalid"
  exit 1
fi

echo "--- Testing: CSP present ---"
HTML=$(curl -s "$BASE_URL/")
CSP_COUNT=$(printf '%s' "$HTML" | grep -c "Content-Security-Policy" || true)
if [ "$CSP_COUNT" -gt 0 ]; then
  echo "PASS: CSP found in HTML"
else
  echo "WARN: No CSP in HTML"
fi

echo "--- Testing: Security headers ---"
HEADERS=$(curl -s -I "$BASE_URL/")
if printf '%s' "$HEADERS" | grep -q "X-Content-Type-Options"; then
  echo "PASS: X-Content-Type-Options present"
else
  echo "INFO: Security headers not sent (may be static file server)"
fi

if [ -n "$REQUIRED_CSP_HOSTS" ]; then
  echo "--- Testing: CSP host allowlist ---"
  CSP=$(printf '%s' "$HTML" | grep -o 'content="[^"]*Content-Security-Policy[^"]*"' || printf '%s' "$HTML" | grep -o 'content="[^"]*"' || true)
  for host in $REQUIRED_CSP_HOSTS; do
    if printf '%s' "$CSP" | grep -q "$host"; then
      echo "PASS: $host in CSP"
    else
      echo "FAIL: $host missing from CSP"
      exit 1
    fi
  done
fi

if [ "$CHECK_LOCAL_ENGINE" = "1" ]; then
  # flutter build web --no-web-resources-cdn: the engine comes from canvaskit/ here, not from www.gstatic.com.
  echo "--- Testing: the engine is served from this site ---"
  if curl -s "$BASE_URL/flutter_bootstrap.js" | grep -q '"useLocalCanvasKit":true'; then
    echo "PASS: flutter_bootstrap.js loads the engine locally"
  else
    echo "FAIL: flutter_bootstrap.js loads the engine from Google's CDN; build with --no-web-resources-cdn"
    exit 1
  fi
  for engine in canvaskit/canvaskit.wasm canvaskit/skwasm.wasm; do
    expect_wasm "$engine"
  done
fi

if [ "$CHECK_FALLBACK_FONTS" = "1" ]; then
  # The engine fetches emoji and symbol fonts from fontFallbackBaseUrl, fonts.gstatic.com unless flutter_bootstrap.js names another.
  echo "--- Testing: the fallback fonts are served from this site ---"
  FONT_BASE=$(curl -s "$BASE_URL/flutter_bootstrap.js" | grep -aoE "fontFallbackBaseUrl\"?[[:space:]]*:[[:space:]]*[\"'][^\"']*" | sed -E "s/.*[\"']//" | head -n 1 || true)
  case "$FONT_BASE" in
    "" | *://* | //*)
      echo "FAIL: flutter_bootstrap.js sets no fontFallbackBaseUrl on this site (got '${FONT_BASE}'); see linux/webserver/README.md#fallback-fonts-from-the-site"
      exit 1
      ;;
  esac
  FONT_COUNT=0
  while read -r _sha _file url; do
    case "$_sha" in "" | \#*) continue ;; esac
    url="${url%$'\r'}"
    font="${FONT_BASE%/}/${url#https://fonts.gstatic.com/s/}"
    expect_http_200 "${font#/}" "${font#/}"
    FONT_COUNT=$((FONT_COUNT + 1))
  done < "$FALLBACK_FONTS_LOCK"
  echo "PASS: all ${FONT_COUNT} locked fallback fonts served under ${FONT_BASE}"
fi

if [ "$CHECK_LOADING_SHELL" = "1" ]; then
  # The shared shell (shared/web/README.md): its markup in index.html, its files beside it.
  echo "--- Testing: the shared loading shell ---"
  for needle in 'class="loading"' 'id="background-animation"' 'id="cookie-notice"' 'javascript/init.js' 'css/loading_animation.css'; do
    if printf '%s' "$HTML" | grep -qF "$needle"; then
      echo "PASS: index.html has $needle"
    else
      echo "FAIL: index.html lacks $needle"
      exit 1
    fi
  done
  for asset in javascript/utils.js javascript/cookies.js javascript/init.js css/cookie.css css/loading_animation.css; do
    expect_http_200 "$asset" "$asset"
    echo "PASS: $asset served"
  done
fi

echo ""
echo "=== All critical checks passed ==="
