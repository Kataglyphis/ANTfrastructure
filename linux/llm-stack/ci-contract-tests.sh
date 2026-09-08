#!/usr/bin/env bash
# ci-contract-tests.sh — run the llm-stack test suite against a live
# OpenAI-compatible endpoint. The exact command CI runs, runnable locally.
#
# This body was inline in .github/workflows/llm-stack-tests.yml: a readiness
# loop, a model pull and a pytest invocation. Nothing outside that workflow
# could reproduce the run, and the workflow's own header had drifted from what
# it executed - it described the suite as linux/llm-stack/tests/test_v1_api.py
# while the command pointed pytest at the whole tests/ directory. The command
# below is UNCHANGED (narrowing it would drop coverage that is green today); it
# was the prose that was wrong.
#
# `-m "not inference"` is the real narrowing: the inference-marked tests need a
# loaded model producing meaningful output and stay local-only. Everything else
# needs only a serving API with >=1 model present.
#
# OLLAMA_BASE_URL and TEST_TIMEOUT are read by tests/test_v1_api.py itself and
# are deliberately NOT re-read here - this script takes the endpoint it probes
# as an argument so the readiness loop and the suite cannot end up pointed at
# two different servers.
#
# Usage:
#   bash linux/llm-stack/ci-contract-tests.sh [base-url] [model-tag]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BASE_URL="http://localhost:11434"
# Explicit `if`, not `[ ... ] && VAR=x`: under `set -e` a false && chain IS the
# command's exit status and would end the script here instead of taking a default.
if [ $# -ge 1 ] && [ -n "$1" ]; then BASE_URL="$1"; fi
# Smallest practical tag; it only has to EXIST in /v1/models - the
# non-inference tests never require a meaningful generation.
MODEL="qwen2.5:0.5b"
if [ $# -ge 2 ] && [ -n "$2" ]; then MODEL="$2"; fi

echo "== waiting for ${BASE_URL} =="
for _ in $(seq 1 30); do
  curl -fsS "${BASE_URL}/api/tags" >/dev/null 2>&1 && break
  sleep 2
done
# Unconditional and unsilenced: if the service never came up this is where the
# run stops, with curl's error, instead of inside pytest 30 lines later.
curl -fsS "${BASE_URL}/api/tags" >/dev/null

echo "== pulling ${MODEL} =="
curl -fsS "${BASE_URL}/api/pull" -d "{\"name\":\"${MODEL}\"}" | tail -c 200
echo

echo "== pytest linux/llm-stack/tests -m 'not inference' =="
python3 -m pytest linux/llm-stack/tests/ -v -m "not inference"
