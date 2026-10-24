#!/usr/bin/env bash
# Disposable files cover ordered media completeness checks, not SDK downloads or compiler output validity.
exec python3 "${BASH_SOURCE[0]%/*}/media_file_set_tests.py" "${1:-${BASH_SOURCE[0]%/*}/../03-media}"
