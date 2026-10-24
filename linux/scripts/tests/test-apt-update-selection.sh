#!/usr/bin/env bash
# Empty PATH fences unqualified tools; actual package operations and arbitrary absolute commands are outside coverage.
set -eu
exec python3 "$(dirname "${BASH_SOURCE[0]}")/apt-update-selection-tests.py" "$@"
