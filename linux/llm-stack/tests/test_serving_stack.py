"""The serving stack's shape, without starting it.

The benchmark suite that used to grade this directory moved to OrchestrANT;
what is left is host infrastructure, and these are the properties that make it
infrastructure rather than a set of files: the compose files parse, the ollama
image is built from the local Dockerfile, every PULLED image is pinned away
from a mutable tag, and the backend registry both consumers rely on still holds
its default lane and its GenieX entries.
"""
import json
import pathlib

import yaml

HERE = pathlib.Path(__file__).resolve().parent.parent

COMPOSE = HERE / "docker-compose.yml"
OVERLAYS = ("docker-compose.gpu.yml", "docker-compose.lan.yml")
REGISTRY = HERE / "backends.json"


def _compose(*paths):
    doc = yaml.safe_load((HERE / paths[0]).read_text(encoding="utf-8"))
    for extra in paths[1:]:
        overlay = yaml.safe_load((HERE / extra).read_text(encoding="utf-8"))
        doc["services"].update(overlay.get("services", {}))
    return doc


def test_compose_parses_and_builds_ollama_locally():
    services = _compose("docker-compose.yml")["services"]
    assert "ollama" in services, "the ollama service is the stack's reason to exist"
    assert services["ollama"].get("build") in (".", {}), \
        "the ollama service must build the local Dockerfile, not pull a moving tag"


def test_no_pulled_image_rides_a_mutable_tag():
    services = _compose("docker-compose.yml")["services"]
    for name, service in services.items():
        image = service.get("image")
        if image is None:
            continue
        assert ":latest" not in image, f"{name} pulls a mutable tag: {image}"
        assert "@sha256:" in image or ":" in image, f"{name} has no tag: {image}"


def test_the_overlays_parse():
    _compose("docker-compose.yml", *OVERLAYS)


def test_the_registry_keeps_its_default_and_genie_lanes():
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    backends = data["backends"]
    assert data["default"] == "ollama", "ollama must stay the default lane"
    assert "ollama" in backends
    assert any(name.startswith("geniex-") for name in backends), \
        "the Snapdragon lanes are half the registry's point"
    for name, entry in backends.items():
        assert entry.get("base_url"), f"{name} has no base_url"


def test_no_entry_stores_a_key_rather_than_its_variable_name():
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    for name, entry in data["backends"].items():
        for field in ("api_key", "key", "token"):
            assert field not in entry, \
                f"{name} appears to carry a credential; name the env var instead"
        if "api_key_env" in entry:
            assert entry["api_key_env"].isupper(), \
                f"{name}.api_key_env must name an environment variable"
