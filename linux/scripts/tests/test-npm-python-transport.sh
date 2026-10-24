#!/usr/bin/env bash
# Fake HTTP and tar commands cover quiet Python transport, not registry or archive validity.
exec python3 "${BASH_SOURCE[0]%/*}/npm_python_transport_tests.py" "${1:-${BASH_SOURCE[0]%/*}/../03-media/build/litert/install-litert-web.sh}"
