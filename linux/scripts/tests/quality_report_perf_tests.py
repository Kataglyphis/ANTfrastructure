"""quality-report --perf-host on fixture checkouts and a fixture engine; it never starts the image, so
it does not prove the real nerdctl mounts, the consumers' timing commands or the host's quietness."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
HUB = SCRIPTS.parents[1]
sys.path.insert(0, str(SCRIPTS))

import quality_report
import quality_report_perf as perf

GIT_ENV = {"GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
TOML = """schema_version = 1
[perf]
cpus = 2
[[perf.command]]
name = "detector"
run = "cat logs/v/detector/$QUALITY_PERF_RUN.json"
metrics = [{ key = "p50_ms", unit = "ms", better = "lower" }]
[[perf.command]]
name = "text"
run = "cat logs/v/text/$QUALITY_PERF_RUN.json"
metrics = [{ key = "decode_tok_s", unit = "tok/s", better = "higher" }]
"""
# Maps the image paths onto their bind sources and runs the command here, as the real engine would there.
ENGINE = r"""#!/usr/bin/env bash
[ "$1" = run ] || exit 3
shift
maps=() workdir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rm) shift ;;
    --user) printf '%s\n' "$2" >> "${FIXTURE_USERS}"; shift 2 ;;
    --name|--platform|--security-opt) shift 2 ;;
    -v) maps+=("$2"); shift 2 ;;
    -w) workdir="$2"; shift 2 ;;
    *) break ;;
  esac
done
cmd="$4"
for m in "${maps[@]}"; do
  src="${m%%:*}" rest="${m#*:}"
  cmd="${cmd//"${rest%%:*}"/"${src}"}" workdir="${workdir//"${rest%%:*}"/"${src}"}"
done
echo started >> "${FIXTURE_STARTS}"
cd "${workdir}" && HOME="${FIXTURE_HOME}" exec bash -c "${cmd}"
"""
LSCPU = "#!/usr/bin/env bash\nprintf 'Architecture: x86_64\\nModel name:   Fixture CPU 9000\\n'\n"
BASELINE = "perf/baseline-fixture-cpu-9000.json"


def git(cwd: Path, *args: str) -> None:
    """One fixture git command; a failure fails the fixture."""
    subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=cwd, check=True,
                   capture_output=True, env={**os.environ, **GIT_ENV})


class PerfHost(unittest.TestCase):
    """One committed fixture consumer, a fixture engine and lscpu on PATH, and a quiet load."""

    def setUp(self) -> None:
        self.base = Path(tempfile.mkdtemp(prefix="perf-host-"))
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        bin_dir = self.base.joinpath("bin")
        bin_dir.mkdir()
        for name, body in (("nerdctl", ENGINE), ("lscpu", LSCPU)):
            bin_dir.joinpath(name).write_text(body, encoding="utf-8")
            bin_dir.joinpath(name).chmod(0o755)
        self.base.joinpath("home").mkdir()
        self.starts = self.base.joinpath("starts")
        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "TMPDIR": str(self.base),
               "FIXTURE_HOME": str(self.base.joinpath("home")), "FIXTURE_STARTS": str(self.starts),
               "FIXTURE_USERS": str(self.base.joinpath("users"))}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        load = mock.patch.object(perf, "load_average", return_value=0.5)
        self.load = load.start()
        self.addCleanup(load.stop)
        self.root = self.base.joinpath("consumer")
        self.root.mkdir()
        self.root.joinpath(".gitignore").write_text("logs/\n", encoding="utf-8")
        self.root.joinpath("quality-report.toml").write_text(TOML, encoding="utf-8")
        git(self.base, "init", "-q", str(self.root))
        self.commit()

    def commit(self) -> None:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture", "--allow-empty")

    def values(self, command: str, key: str, samples: list[object]) -> None:
        """The JSON line each of the 20 runs of a fixture command prints."""
        folder = self.root.joinpath("logs", "v", command)
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        for index in range(perf.RUNS):
            folder.joinpath(f"{index}.json").write_text(
                json.dumps({key: samples[index % len(samples)]}) + "\n", encoding="utf-8")

    def steady(self, detector: float = 20.0, text: float = 100.0) -> None:
        self.values("detector", "p50_ms", [detector * f for f in (0.99, 1.0, 1.01)])
        self.values("text", "decode_tok_s", [text * f for f in (0.99, 1.0, 1.01)])

    def run_perf(self, *extra: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = quality_report.main(["--root", str(self.root), "--hub", str(HUB), "--perf-host", *extra])
        return rc, out.getvalue()

    def record_baseline(self) -> None:
        rc, out = self.run_perf("--update-baseline")
        self.assertEqual(rc, 0, out)
        self.commit()


class Baseline(PerfHost):
    def test_update_writes_twenty_samples_per_metric(self) -> None:
        self.steady()
        self.record_baseline()
        data = json.loads(self.root.joinpath(BASELINE).read_text(encoding="utf-8"))
        self.assertEqual(data["cpu_model"], "Fixture CPU 9000")
        self.assertEqual(len(data["metrics"]["perf.detector.p50_ms"]["samples"]), 20)
        self.assertEqual(len(data["metrics"]["perf.text.decode_tok_s"]["samples"]), 20)
        self.assertEqual(data["cpus"], sorted(os.sched_getaffinity(0))[:2])

    def test_image_runs_as_the_user_who_owns_the_checkout(self) -> None:
        self.steady()
        self.record_baseline()
        self.assertEqual(self.base.joinpath("users").read_text(encoding="utf-8").strip(), "0:0")

    def test_noisy_update_is_refused(self) -> None:
        self.values("detector", "p50_ms", [10.0, 20.0, 30.0])
        self.values("text", "decode_tok_s", [100.0])
        rc, out = self.run_perf("--update-baseline")
        self.assertEqual(rc, 2, out)
        self.assertIn("refused: perf.detector.p50_ms spread", out)
        self.assertFalse(self.root.joinpath(BASELINE).exists())


class Grading(PerfHost):
    def setUp(self) -> None:
        super().setUp()
        self.steady()
        self.record_baseline()

    def test_same_figures_hold_with_ratios(self) -> None:
        rc, out = self.run_perf()
        self.assertEqual(rc, 0, out)
        self.assertIn("quality-report: verdict=ok regressed=0 improved=0 metrics=2", out)
        self.assertIn("ratio perf.detector.p50_ms 1.000 held", out)

    def test_slower_detector_regresses(self) -> None:
        self.steady(detector=23.0)
        rc, out = self.run_perf()
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED perf.detector.p50_ms 20 -> 23", out)

    def test_fewer_tokens_per_second_regresses(self) -> None:
        self.steady(text=85.0)
        rc, out = self.run_perf()
        self.assertEqual(rc, 1, out)
        self.assertIn("REGRESSED perf.text.decode_tok_s 100 -> 85", out)

    def test_faster_detector_improves(self) -> None:
        self.steady(detector=15.0)
        rc, out = self.run_perf()
        self.assertEqual(rc, 0, out)
        self.assertIn("improved=1", out)

    def test_one_outlier_run_holds(self) -> None:
        self.values("detector", "p50_ms", [80.0] + [20.0] * 19)
        rc, out = self.run_perf()
        self.assertEqual(rc, 0, out)

    def test_missing_baseline_is_incomplete(self) -> None:
        self.root.joinpath(BASELINE).unlink()
        self.commit()
        rc, out = self.run_perf()
        self.assertEqual(rc, 2, out)
        self.assertIn("problem: no baseline for 'Fixture CPU 9000'", out)


class SpreadLimit(PerfHost):
    def test_limit_is_three_spreads_when_wider_than_ten_percent(self) -> None:
        self.values("detector", "p50_ms", [19.2, 20.0, 20.8])
        self.values("text", "decode_tok_s", [100.0])
        self.record_baseline()
        self.values("detector", "p50_ms", [22.2])
        rc, out = self.run_perf()
        self.assertEqual(rc, 0, out)
        self.assertIn("limit 12.0%", out)

    def test_limit_is_ten_percent_on_a_steady_baseline(self) -> None:
        self.steady()
        self.record_baseline()
        self.values("detector", "p50_ms", [22.2])
        rc, out = self.run_perf()
        self.assertEqual(rc, 1, out)


class Refusals(PerfHost):
    def assert_refused(self, reason: str) -> None:
        rc, out = self.run_perf()
        self.assertEqual(rc, 2, out)
        self.assertIn(f"problem: refused: {reason}", out)
        self.assertFalse(self.starts.exists(), "the image ran despite the refusal")

    def test_dirty_tree_is_refused(self) -> None:
        self.steady()
        self.root.joinpath("quality-report.toml").write_text(TOML + "# edited\n", encoding="utf-8")
        self.assert_refused("the checkout is dirty")

    def test_busy_host_is_refused(self) -> None:
        self.steady()
        self.load.return_value = 2.5
        self.assert_refused("1-minute load 2.50 is above 2")

    def test_running_chain_is_refused(self) -> None:
        self.steady()
        self.base.joinpath("kata-cross-chain.pid").write_text("1\n", encoding="utf-8")
        self.assert_refused("an image chain is running")

    def test_update_is_refused_too(self) -> None:
        self.steady()
        self.load.return_value = 3.0
        rc, out = self.run_perf("--update-baseline")
        self.assertEqual(rc, 2, out)
        self.assertFalse(self.root.joinpath(BASELINE).exists())


class Answers(PerfHost):
    def test_unavailable_provider_is_not_collected(self) -> None:
        self.steady()
        self.record_baseline()
        self.values("text", "not_collected", ["ProviderUnavailable: no libdnnl.so.3"])
        rc, out = self.run_perf()
        self.assertEqual(rc, 0, out)
        self.assertIn("not-collected: perf.text.decode_tok_s (ProviderUnavailable: no libdnnl.so.3)", out)

    def test_failed_command_is_incomplete(self) -> None:
        self.steady()
        self.record_baseline()
        shutil.rmtree(self.root.joinpath("logs", "v", "text"))
        rc, out = self.run_perf()
        self.assertEqual(rc, 2, out)
        self.assertIn("problem: perf.text.decode_tok_s: run 1: exited 1", out)

    def test_zero_value_is_incomplete(self) -> None:
        self.steady()
        self.values("detector", "p50_ms", [0])
        rc, out = self.run_perf("--update-baseline")
        self.assertEqual(rc, 2, out)
        self.assertIn("not a positive number", out)


class GenaiThreads(unittest.TestCase):
    def test_copy_fixes_the_decoder_thread_count(self) -> None:
        base = Path(tempfile.mkdtemp(prefix="genai-threads-"))
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        model = base.joinpath("model")
        model.mkdir()
        config = {"model": {"decoder": {"session_options": {"log_id": "x"}}}}
        model.joinpath("genai_config.json").write_text(json.dumps(config), encoding="utf-8")
        model.joinpath("model.onnx").write_text("weights", encoding="utf-8")
        out = base.joinpath("out")
        subprocess.run([sys.executable, str(SCRIPTS.joinpath("lib", "genai-model-threads.py")), "--model", str(model),
                        "--out", str(out), "--threads", "7"], check=True)
        options = json.loads(out.joinpath("genai_config.json").read_text(encoding="utf-8"))
        self.assertEqual(options["model"]["decoder"]["session_options"], {"log_id": "x", "intra_op_num_threads": 7})
        self.assertEqual(out.joinpath("model.onnx").read_text(encoding="utf-8"), "weights")
        self.assertEqual(json.loads(model.joinpath("genai_config.json").read_text(encoding="utf-8")), config)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *sys.argv[1:]])
