#!/usr/bin/env python3
"""Exercise Unix child-cache isolation and cleanup, not .NET internals or native Windows profiles."""

import concurrent.futures
import importlib.util
import json
import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path
from typing import TypedDict
from unittest.mock import patch

GATE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(GATE.parent))
SPEC = importlib.util.spec_from_file_location("cache_fixture_gate", GATE)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
CHILD = r"""import json, os, sys, time
from pathlib import Path
from typing import TypedDict
trace, ready, status, hold, pair = sys.argv[1:]
trace, ready = Path(trace), Path(ready)
cache = Path(os.environ['XDG_CACHE_HOME'])
(cache / 'powershell').mkdir(parents=True, exist_ok=True)
(cache / 'powershell' / 'StartupProfileData-NonInteractive').write_text(ready.name)
trace.write_text(json.dumps({'cache': str(cache), 'home': os.environ.get('HOME'), 'cwd': os.getcwd()}))
ready.touch()
if pair == 'yes':
    deadline = time.monotonic() + 10
    while not all((ready.parent / name).exists() for name in ('ready-0', 'ready-1')):
        if time.monotonic() > deadline: raise SystemExit('peer did not overlap')
        time.sleep(0.02)
print('cache-child-started', file=sys.stderr, flush=True)
time.sleep(float(hold))
raise SystemExit(int(status))
"""


class CacheTrace(TypedDict):
    cache: str
    home: str | None
    cwd: str


@unittest.skipIf(os.name == "nt", "Unix startup cache isolation")
class CacheIsolationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ant-mutation-cache-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ambient = self.root / "ambient"
        self.ambient.mkdir()
        (self.ambient / "sentinel").write_text("preserve")
        self.environment = patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.ambient)})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def run_child(self, index: int, status: int = 0, hold: float = 0, pair: str = "no", timeout: float = 15) -> tuple[int | None, bool, str]:
        argv = [sys.executable, "-c", CHILD, str(self.root / f"trace-{index}.json"),
                str(self.root / f"ready-{index}"), str(status), str(hold), pair]
        return MODULE._run_test(shlex.join(argv), str(self.root), timeout)

    def trace(self, index: int) -> CacheTrace:
        return json.loads((self.root / f"trace-{index}.json").read_text())

    def test_parallel_children_have_private_caches_and_keep_caller_context(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.run_child, n, pair="yes") for n in range(2)]
            results = [future.result() for future in futures]
        self.assertEqual([(result[0], result[1]) for result in results], [(0, False), (0, False)])
        traces = [self.trace(n) for n in range(2)]
        self.assertNotEqual(traces[0]["cache"], traces[1]["cache"])
        for trace in traces:
            self.assertNotEqual(trace["cache"], str(self.ambient))
            self.assertEqual(trace["home"], os.environ.get("HOME"))
            self.assertEqual(trace["cwd"], str(self.root))
            self.assertFalse(Path(trace["cache"]).exists())
        self.assertEqual(os.environ["XDG_CACHE_HOME"], str(self.ambient))
        self.assertEqual([p.name for p in self.ambient.iterdir()], ["sentinel"])
        self.assertFalse(MODULE._LIVE_GROUPS)

    def test_failure_retains_raw_status_and_cleans_its_cache(self) -> None:
        status, timed_out, output = self.run_child(2, status=23)
        self.assertEqual(status, 23)
        self.assertFalse(timed_out)
        self.assertIn("cache-child-started", output)
        self.assertFalse(Path(self.trace(2)["cache"]).exists())

    def test_timeout_reaps_before_cache_cleanup(self) -> None:
        _, timed_out, output = self.run_child(3, hold=30, timeout=3)
        self.assertTrue(timed_out)
        self.assertIn("cache-child-started", output)
        self.assertFalse(Path(self.trace(3)["cache"]).exists())
        self.assertFalse(MODULE._LIVE_GROUPS)

    def test_windows_path_keeps_the_existing_environment_policy(self) -> None:
        with patch.object(MODULE.os, "name", "nt"):
            status, timed_out, _ = self.run_child(4)
        self.assertEqual((status, timed_out), (0, False))
        self.assertEqual(self.trace(4)["cache"], str(self.ambient))


if __name__ == "__main__":
    unittest.main()
