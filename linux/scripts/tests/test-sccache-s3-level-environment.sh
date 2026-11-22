#!/usr/bin/env bash
# Exercise fake server startup under inherited cache settings; no real S3 credentials, uploads or compile-cache proof.
set -euo pipefail
SCCACHE_MULTILEVEL_CHAIN=fixture-inherited bash "$(dirname "${BASH_SOURCE[0]}")/test-sccache-s3-level.sh"
