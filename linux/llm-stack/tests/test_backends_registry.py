"""Tests for the named-backend registry.

The registry exists so the two backends this repo actually serves -- the Ollama
service in docker-compose.yml and the Snapdragon GenieX lanes -- are addressable
by name instead of by a URL typed from memory.

The resolution ORDER is the part worth pinning down. Getting it wrong is the
kind of bug that wastes an afternoon: you export an env var, pass --backend,
and quietly benchmark the wrong machine.
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from benchmark_openai_api import load_backends, resolve_backend  # noqa: E402


@pytest.fixture
def registry(tmp_path):
    path = tmp_path / "backends.json"
    path.write_text(json.dumps({
        "default": "ollama",
        "backends": {
            "ollama": {"base_url": "http://localhost:11434"},
            "npu": {"base_url": "http://127.0.0.1:18181/", "model": "org/Model:W4A16"},
        },
    }))
    return str(path)


class TestShippedRegistry:
    def test_repo_registry_parses_and_lists_both_backends(self):
        backends, default = load_backends()
        assert default == "ollama", "ollama must stay the default backend"
        assert "ollama" in backends
        assert any(n.startswith("geniex-") for n in backends)

    def test_every_entry_has_a_base_url(self):
        backends, _ = load_backends()
        missing = [n for n, e in backends.items() if not e.get("base_url")]
        assert missing == [], f"entries without base_url: {missing}"


class TestResolutionOrder:
    @pytest.fixture(autouse=True)
    def _ambient_env_cleared(self, monkeypatch):
        # Env legitimately beats the registry (TestEnvironmentPrecedence pins
        # that); these cases assert the order BELOW env, so the host's/CI's own
        # endpoint vars must not leak in (the v1-api-contract job exports
        # OLLAMA_BASE_URL for its service container and turned all three red).
        for var in ("LLM_BASE_URL", "OLLAMA_BASE_URL", "OLLAMA_HOST"):
            monkeypatch.delenv(var, raising=False)

    def test_named_backend(self, registry):
        url, model, source = resolve_backend("npu", path=registry)
        assert url == "http://127.0.0.1:18181"   # trailing slash stripped
        assert model == "org/Model:W4A16"
        assert "npu" in source

    def test_default_when_nothing_given(self, registry):
        url, _, source = resolve_backend(path=registry)
        assert url == "http://localhost:11434"
        assert "default" in source

    def test_explicit_url_beats_named_backend(self, registry):
        url, _, source = resolve_backend("npu", base_url="http://elsewhere:1/", path=registry)
        assert url == "http://elsewhere:1"
        assert source == "--base-url"

    def test_unknown_backend_fails_loudly_and_lists_options(self, registry):
        # Silently falling back to the default would benchmark the wrong host.
        with pytest.raises(SystemExit) as e:
            resolve_backend("typo", path=registry)
        assert "typo" in str(e.value) and "ollama" in str(e.value)

    def test_missing_registry_still_resolves_an_explicit_url(self, tmp_path):
        # A broken config must not block someone benchmarking a plain URL.
        gone = str(tmp_path / "nope.json")
        url, _, _ = resolve_backend(base_url="http://h:1", path=gone)
        assert url == "http://h:1"

    def test_malformed_registry_does_not_raise(self, tmp_path):
        bad = tmp_path / "bad.json"
        bad.write_text("{ not json")
        backends, default = load_backends(str(bad))
        assert backends == {} and default is None


class TestEnvironmentPrecedence:
    """Env beats --backend on purpose: a wrapper script that exports the
    variable must not be silently overridden by a stale config default."""

    def _resolve(self, env, args):
        code = (
            "import json,sys;"
            "sys.path.insert(0,%r);"
            "import benchmark_openai_api as b;"
            "print(json.dumps(b.resolve_backend(*%r)))" % (HERE, args)
        )
        child = dict(os.environ)
        for k in ("LLM_BASE_URL", "OLLAMA_BASE_URL"):
            child.pop(k, None)
        child.update(env)
        out = subprocess.run([sys.executable, "-c", code], cwd=HERE, env=child,
                             capture_output=True, text=True, timeout=60)
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout)

    def test_env_beats_named_backend(self):
        url, _, source = self._resolve({"LLM_BASE_URL": "http://env:9"}, ("geniex-npu",))
        assert url == "http://env:9"
        assert source == "environment"

    def test_legacy_env_name_also_beats_backend(self):
        url, _, _ = self._resolve({"OLLAMA_BASE_URL": "http://legacy:9"}, ("geniex-npu",))
        assert url == "http://legacy:9"

    def test_env_still_yields_the_backend_default_model(self):
        # The URL comes from the env, but the named backend's model is still
        # useful -- otherwise you would have to retype it every time.
        _, model, _ = self._resolve({"LLM_BASE_URL": "http://env:9"}, ("geniex-npu",))
        assert model == "qualcomm/Qwen3-4B-Instruct-2507:W4A16"
