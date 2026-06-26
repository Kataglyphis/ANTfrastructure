#!/usr/bin/env bash
# Integration smoke test for a built Flutter web app.
# Requires: curl, a web server serving the target directory.
# Usage: flutter_integration_smoke_test.sh [base_url]

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
REQUIRED_CSP_HOSTS="${REQUIRED_CSP_HOSTS:-www.gstatic.com fonts.gstatic.com}"
CHECK_LOADING_SHELL="${CHECK_LOADING_SHELL:-1}"

echo "=== Integration Smoke Test ==="
echo "Target: $BASE_URL"
echo ""

echo "--- Testing: index.html loads ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
if [ "$STATUS" != "200" ]; then
  echo "FAIL: index.html returned HTTP $STATUS"
  exit 1
fi
echo "PASS: index.html HTTP 200"

echo "--- Testing: main.dart.wasm MIME type ---"
WASM_MIME=$(curl -s -I "$BASE_URL/main.dart.wasm" | grep -i "content-type:" | tr -d '\r')
if printf '%s' "$WASM_MIME" | grep -q "application/wasm"; then
  echo "PASS: WASM MIME type correct"
else
  echo "FAIL: WASM MIME type: $WASM_MIME"
  exit 1
fi

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
  CSP=$(printf '%s' "$HTML" | grep -o 'content="[^"]*Content-Security-Policy[^"]*"' || printf '%s' "$HTML" | grep -o 'content="[^"]*"')
  for host in $REQUIRED_CSP_HOSTS; do
    if printf '%s' "$CSP" | grep -q "$host"; then
      echo "PASS: $host in CSP"
    else
      echo "FAIL: $host missing from CSP"
      exit 1
    fi
  done

  if printf '%s' "$CSP" | grep -q "script-src[^;]*www.gstatic.com"; then
    echo "PASS: script-src permits www.gstatic.com"
  else
    echo "FAIL: script-src missing www.gstatic.com"
    exit 1
  fi
fi

if [ "$CHECK_LOADING_SHELL" = "1" ]; then
  echo "--- Testing: loading screen uses MutationObserver ---"
  if printf '%s' "$HTML" | grep -q "MutationObserver"; then
    echo "PASS: MutationObserver-based loading screen present"
  else
    echo "WARN: MutationObserver not found in loading script"
  fi

  echo "--- Testing: loading screen has hideLoading ---"
  if printf '%s' "$HTML" | grep -q "hideLoading"; then
    echo "PASS: hideLoading function present"
  else
    echo "WARN: hideLoading function not found"
  fi
fi

echo ""
echo "=== All critical checks passed ==="
