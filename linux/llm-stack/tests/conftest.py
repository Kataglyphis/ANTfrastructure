"""Suite-wide guard: a test may reach only a server it bound itself, loopback included."""
import os
import socket

import pytest

# Modules that talk to a live server on purpose and skip when nothing answers.
_LIVE_ENDPOINT_MODULES = {"test_harness_against_ollama.py", "test_v1_api.py"}
# The gateway e2e starts its own APISIX container; it skips unless GATEWAY_E2E=1.
_LIVE_ENDPOINT_DIRS = {"gateway_e2e"}

# Ports bound by this process: a stub server a test started itself.
_OWN_PORTS = set()
_REAL_BIND = socket.socket.bind


def _recording_bind(self, address):
    _REAL_BIND(self, address)
    try:
        _OWN_PORTS.add(self.getsockname()[1])
    except OSError:  # a non-IP socket has no port
        pass


socket.socket.bind = _recording_bind


def pytest_configure(config):
    config.addinivalue_line("markers", "inference: tests that require model inference (slow, needs model loaded)")


class NetworkAccessInATest(RuntimeError):
    """A test tried to reach a server it did not start."""


@pytest.fixture(autouse=True)
def no_network(request, monkeypatch):
    if os.path.basename(str(request.node.fspath)) in _LIVE_ENDPOINT_MODULES:
        return
    if os.path.basename(os.path.dirname(str(request.node.fspath))) in _LIVE_ENDPOINT_DIRS:
        return
    if request.node.get_closest_marker("inference"):
        return
    real_connect = socket.socket.connect

    def guarded(self, address):
        port = address[1] if isinstance(address, tuple) and len(address) > 1 else None
        if port in _OWN_PORTS:
            return real_connect(self, address)
        raise NetworkAccessInATest(
            f"{request.node.nodeid} tried to connect to {address!r}, which no "
            f"test in this process is listening on. These tests run offline: "
            f"monkeypatch the request function (urlopen, or bench_cli.post_json), "
            f"or bind your own stub server. If it genuinely needs a real "
            f"backend, mark it @pytest.mark.inference.")

    monkeypatch.setattr(socket.socket, "connect", guarded)
