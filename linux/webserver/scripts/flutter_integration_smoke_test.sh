#!/usr/bin/env bash
# Integration smoke test for a built Flutter web app, via curl; usage: flutter_integration_smoke_test.sh [base_url]

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
# Hosts the page's CSP must name; none by default, since the family's builds serve their own engine and fonts.
REQUIRED_CSP_HOSTS="${REQUIRED_CSP_HOSTS:-}"
CHECK_LOADING_SHELL="${CHECK_LOADING_SHELL:-1}"
CHECK_LOCAL_ENGINE="${CHECK_LOCAL_ENGINE:-1}"

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

echo "=== Integration Smoke Test ==="
echo "Target: $BASE_URL"
echo ""

# `|| true` on the probes, or set -e kills the script before its FAIL diagnostics print.
echo "--- Testing: index.html loads ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/" || true)
if [ "$STATUS" != "200" ]; then
  echo "FAIL: index.html returned HTTP $STATUS"
  exit 1
fi
echo "PASS: index.html HTTP 200"

echo "--- Testing: main.dart.wasm MIME type ---"
expect_wasm main.dart.wasm

echo "--- Testing: main.dart.js exists ---"
JS_SIZE=$(curl -s -o /dev/null -w "%{size_download}" "$BASE_URL/main.dart.js")
if [ "$JS_SIZE" -gt 10000 ]; then
  echo "PASS: main.dart.js served ($JS_SIZE bytes)"
else
  echo "FAIL: main.dart.js too small or missing ($JS_SIZE bytes)"
  exit 1
fi

echo "--- Testing: flutter_bootstrap.js exists ---"
BOOT_SIZE=$(curl -s -o /dev/null -w "%{size_download}" "$BASE_URL/flutter_bootstrap.js")
if [ "$BOOT_SIZE" -gt 100 ]; then
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
    ASSET_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/$asset" || true)
    if [ "$ASSET_STATUS" = "200" ]; then
      echo "PASS: $asset served"
    else
      echo "FAIL: $asset returned HTTP $ASSET_STATUS"
      exit 1
    fi
  done
fi

echo ""
echo "=== All critical checks passed ==="
