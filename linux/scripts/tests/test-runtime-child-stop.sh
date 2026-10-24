#!/usr/bin/env bash
# Mocked signals cover advisory child reaping; real heartbeat lifetime remains independently tested.
exec python3 "${BASH_SOURCE[0]%/*}/runtime_child_stop_tests.py"
