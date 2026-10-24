#!/usr/bin/env bash
# Fake usage callbacks and copied CLI scripts cover exit policy, not process or container operations.
exec python3 "${BASH_SOURCE[0]%/*}/cli_help_exit_tests.py"
