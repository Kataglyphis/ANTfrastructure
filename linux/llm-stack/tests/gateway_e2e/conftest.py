"""The gateway e2e harness: the pinned APISIX image, started by serve-stack.sh, in
front of three fake lanes this process owns. Opt-in (GATEWAY_E2E=1): it needs a
container engine and the image, and it runs for about a minute.
"""
import os

import pytest
from gw_fake_lane import FakeLane
from gw_harness import Gateway

ENABLED = os.environ.get("GATEWAY_E2E") == "1"


@pytest.fixture(scope="session")
def gateway(tmp_path_factory):
    if not ENABLED:
        pytest.skip("gateway e2e is opt-in: GATEWAY_E2E=1 (needs nerdctl or docker and the pinned image)")
    lanes = {n: FakeLane(n).start() for n in ("npu", "gpu", "cpu")}
    gw = Gateway(str(tmp_path_factory.mktemp("gateway")), lanes)
    up = gw.serve("up")
    try:
        assert up.returncode == 0, f"serve-stack.sh up failed:\n{up.stdout}\n{up.stderr}"
        yield gw
    finally:
        down = gw.serve("down")
        for lane in lanes.values():
            lane.stop()
        assert down.returncode == 0, f"serve-stack.sh down failed:\n{down.stdout}\n{down.stderr}"


@pytest.fixture(autouse=True)
def fresh(gateway):
    for lane in gateway.lanes.values():
        lane.reset()
    gateway.log.mark()
    yield gateway
