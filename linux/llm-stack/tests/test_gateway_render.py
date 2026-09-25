"""The gateway renderer, offline: what it emits from a registry, and what it refuses.

The live half (the pinned APISIX image in front of fake lanes) is gateway_e2e/,
opt-in with GATEWAY_E2E=1; this file needs neither a container nor a network.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys

import pytest
import yaml

HERE = pathlib.Path(__file__).resolve().parent
STACK = HERE.parent
_SPEC = importlib.util.spec_from_file_location("render_apisix", STACK / "gateway" / "render_apisix.py")
ra = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(ra)

SERVE = STACK / "scripts" / "serve-stack.sh"
PROMPT = b"Pick the tool whose name matches.\r\nNever guess arguments.\r\n"
P8_PROMPT_SHA = "970a8e4fcaf8540f55be6011c06ee33489e7915774ffc304d4022482b743e709"


def fixture_doc():
    return {
        "backends": {
            "g-npu": {"base_url": "http://127.0.0.1:18181", "model": "qualcomm/M-4B:W4A16"},
            "g-gpu": {"base_url": "http://127.0.0.1:18182", "model": "org/M-4B-GGUF:Q4_0"},
            "g-cpu": {"base_url": "http://127.0.0.1:18184/", "model": "org/M-9B-GGUF:Q4_K_M"},
        },
        "serving": {
            "gateway": {
                "listen": "127.0.0.1:9080", "status_listen": "127.0.0.1:7085",
                "metrics_listen": "127.0.0.1:9091",
                "consumers": {"webui": "GW_KEY_WEBUI", "lab": "GW_KEY_LAB", "agent": "GW_KEY_AGENT"},
                "lab_consumer": "lab", "estimate": {"bytes_per_token": 3.0, "default_reserve": 1024},
                "drop_fields": ["power_mode"], "raw_routes": True,
                "prompts": {"tools": {"file": "tools.md", "sha256": hashlib.sha256(PROMPT).hexdigest()}},
            },
            "lanes": {
                "npu": {"backend": "g-npu", "format": "qairt", "context": 4096, "timeout_s": 300,
                        "t0_rewrite": False},
                "gpu": {"backend": "g-gpu", "format": "gguf", "context": 16384, "timeout_s": 1800,
                        "t0_rewrite": True},
                "cpu": {"backend": "g-cpu", "format": "gguf", "context": 16384, "timeout_s": 1800,
                        "t0_rewrite": True},
            },
            "routes": {
                "chat": {"lane": "npu", "overflow_lane": "gpu", "budget_tokens": 3900,
                         "tools_prompt": "tools"},
                "chat-long": {"lane": "gpu"},
                "agent": {"lane": "cpu"},
            },
        },
    }


@pytest.fixture
def tree(tmp_path):
    (tmp_path / "prompts").mkdir()
    (tmp_path / "prompts" / "tools.md").write_bytes(PROMPT)
    return tmp_path


def write_doc(tree, doc):
    path = tree / "backends.json"
    path.write_text(json.dumps(doc), encoding="utf-8")
    return str(path)


def render_doc(tree, doc=None):
    files, meta = ra.render(write_doc(tree, doc or fixture_doc()), str(tree / "prompts"),
                            ra.DEFAULT_OVERLAY)
    return json.loads(files["apisix.json"]), files, meta


def routes_by_id(document):
    return {r["id"]: r for r in document["routes"]}


# --- the shipped registry --------------------------------------------------------------

def shipped():
    return json.loads((STACK / "backends.json").read_text(encoding="utf-8"))


def test_the_shipped_serving_block_is_valid():
    serving = ra.parse_serving(shipped())
    assert [r["alias"] for r in serving["routes"]] == ["chat", "chat-long", "agent"]
    assert serving["lanes"]["gpu"]["model"] == "unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_0"
    assert serving["lanes"]["cpu"]["model"] == "empero-ai/Qwen3.8-9B-Distill-GGUF:Q4_K_M"
    assert serving["lanes"]["npu"]["timeout_ms"] == 300000
    assert not serving["lanes"]["npu"]["t0_rewrite"], "owner decision: no T=0 rewrite on the NPU"
    assert serving["gateway"]["prompts"]["tool-disambiguation"]["sha256"] == P8_PROMPT_SHA


def test_geniex_cpu_keeps_the_model_the_lab_measures():
    assert shipped()["backends"]["geniex-cpu"]["model"] == "unsloth/Qwen3-4B-GGUF:Q4_0"


def test_the_lab_entries_go_through_the_gateway_with_the_lab_key():
    backends = shipped()["backends"]
    lab = {n: e for n, e in backends.items() if n.startswith("lab-")}
    assert sorted(lab) == ["lab-agent", "lab-chat", "lab-chat-long", "lab-raw-cpu", "lab-raw-gpu",
                           "lab-raw-npu"]
    for name, entry in lab.items():
        assert entry["base_url"] == "http://127.0.0.1:9080", name
        assert entry["api_key_env"] == "GW_KEY_LAB" and entry["probe"] is False, name
        assert entry["model"] == name[len("lab-"):], name


def test_the_shipped_registry_will_not_render_without_the_prompt(tree):
    with pytest.raises(ra.RenderError, match=ra.PROMPTS_ENV):
        ra.render(str(STACK / "backends.json"), None, ra.DEFAULT_OVERLAY)
    lf = tree / "lf"
    lf.mkdir()
    (lf / "tool-disambiguation.md").write_bytes(b"the LF blob, not the measured bytes\n")
    with pytest.raises(ra.RenderError, match="line endings included"):
        ra.render(str(STACK / "backends.json"), str(lf), ra.DEFAULT_OVERLAY)


# --- what it emits ----------------------------------------------------------------------

def test_routes_and_priorities(tree):
    routes = routes_by_id(render_doc(tree)[0])
    assert list(routes) == ["gateway-info", "chat-presend", "chat", "chat-long", "agent",
                            "raw-npu", "raw-gpu", "raw-cpu", "models", "unknown-model"]
    assert routes["chat-presend"]["priority"] == 30
    assert routes["chat-presend"]["vars"] == [["post_arg.model", "==", "chat"],
                                              ["gw_est_tokens", ">", 3900]]
    assert routes["chat"]["priority"] == 20 and routes["unknown-model"]["priority"] == 0
    for rid in ("chat", "chat-long", "agent", "raw-npu"):
        assert routes[rid]["plugins"]["key-auth"] == {"header": "Authorization", "hide_credentials": True}
        assert routes[rid]["uris"] == ["/v1/chat/completions", "/v1/completions"]


def test_only_chat_can_fall_back_and_only_once(tree):
    routes = routes_by_id(render_doc(tree)[0])
    proxy = routes["chat"]["plugins"]["ai-proxy-multi"]
    assert [(i["name"], i["priority"]) for i in proxy["instances"]] == [("npu", 1), ("gpu", 0)]
    assert (proxy["fallback_strategy"], proxy["max_retries"]) == (["http_5xx"], 1)
    assert proxy["retry_on_failure_within_ms"] == 299000, "a timed-out NPU is never retried"
    assert proxy["timeout"] == 1800000 and proxy["keepalive"] is False
    assert proxy["streaming_flush_interval_ms"] == 0
    for rid in ("chat-presend", "chat-long", "agent", "raw-npu", "raw-gpu", "raw-cpu"):
        single = routes[rid]["plugins"]["ai-proxy-multi"]
        assert len(single["instances"]) == 1 and "fallback_strategy" not in single, rid
    assert not any("checks" in i for r in routes.values()
                   for i in r["plugins"].get("ai-proxy-multi", {}).get("instances", [])), "R10"


def test_instances_pin_the_lane_model_and_hide_the_client_key(tree):
    routes = routes_by_id(render_doc(tree)[0])
    (cpu,) = routes["agent"]["plugins"]["ai-proxy-multi"]["instances"]
    assert cpu["options"] == {"model": "org/M-9B-GGUF:Q4_K_M"}
    assert cpu["override"] == {"endpoint": "http://127.0.0.1:18184"}
    assert cpu["auth"] == {"header": {"Authorization": "Bearer unused"}}


def test_lane_policy_per_route(tree):
    routes = routes_by_id(render_doc(tree)[0])
    shape = routes["chat"]["plugins"]["geniex-shape"]
    assert shape["lanes"] == {
        "npu": {"timeout_ms": 300000, "t0_rewrite": False, "overflow_relabel": True},
        "gpu": {"timeout_ms": 1800000, "t0_rewrite": True, "overflow_relabel": False}}
    assert routes["chat-presend"]["plugins"]["geniex-shape"]["lanes"] == {
        "gpu": {"timeout_ms": 1800000, "t0_rewrite": True, "overflow_relabel": False}}
    for lane in ("npu", "gpu", "cpu"):
        raw = routes[f"raw-{lane}"]["plugins"]
        assert raw["geniex-shape"]["drop_fields"] == [] and "tools_prompt" not in raw["geniex-shape"]
        assert not raw["geniex-shape"]["lanes"][lane]["t0_rewrite"]
        assert raw["consumer-restriction"] == {"whitelist": ["lab"]}


def test_the_prompt_rides_as_its_exact_bytes(tree):
    routes = routes_by_id(render_doc(tree)[0])
    for rid in ("chat", "chat-presend"):
        tp = routes[rid]["plugins"]["geniex-shape"]["tools_prompt"]
        assert base64.b64decode(tp["b64"]) == PROMPT
        assert tp["sha256"] == hashlib.sha256(PROMPT).hexdigest()
    assert "tools_prompt" not in routes["chat-long"]["plugins"]["geniex-shape"]


def test_consumers_metadata_and_log(tree):
    document = render_doc(tree)[0]
    assert [c["plugins"]["key-auth"]["key"] for c in document["consumers"]] == [
        "Bearer ${{GW_KEY_WEBUI}}", "Bearer ${{GW_KEY_LAB}}", "Bearer ${{GW_KEY_AGENT}}"]
    (meta,) = document["plugin_metadata"]
    assert meta == {"id": "geniex-shape", "bytes_per_token": 3.0, "default_reserve": 1024,
                    "prompt_bytes": {"chat": len(PROMPT)}}
    (rule,) = document["global_rules"]
    assert rule["plugins"]["file-logger"]["path"] == "/var/log/gateway/requests.jsonl"
    assert rule["plugins"]["prometheus"] == {"prefer_name": True}


def test_static_bodies(tree):
    routes = routes_by_id(render_doc(tree)[0])
    models = json.loads(routes["models"]["plugins"]["mocking"]["response_example"])
    assert [m["id"] for m in models["data"]] == ["chat", "chat-long", "agent"]
    unknown = routes["unknown-model"]["plugins"]["mocking"]
    assert unknown["response_status"] == 404
    assert json.loads(unknown["response_example"])["error"]["code"] == "model_not_found"


def test_gateway_info_hashes_everything_else(tree):
    document, files, meta = render_doc(tree)
    info_route = document["routes"].pop(0)
    info = json.loads(info_route["plugins"]["mocking"]["response_example"])
    assert info["config_sha256"] == hashlib.sha256(ra.canonical(document).encode()).hexdigest()
    assert info["boot_config_sha256"] == hashlib.sha256(files["config.yaml"]).hexdigest()
    assert info["lua_sha256"]["geniex_hook.lua"] == hashlib.sha256(files["lua/geniex_hook.lua"]).hexdigest()
    assert meta["key_vars"] == ["GW_KEY_WEBUI", "GW_KEY_LAB", "GW_KEY_AGENT"]


def test_the_boot_config_is_localhost_only(tree):
    boot = yaml.safe_load(render_doc(tree)[1]["config.yaml"])
    apisix = boot["apisix"]
    assert apisix["node_listen"] == [{"ip": "127.0.0.1", "port": 9080}]
    assert apisix["ssl"]["enable"] is False and apisix["enable_ipv6"] is False
    assert apisix["enable_control"] is False and apisix["enable_admin"] is False
    assert apisix["status"] == {"ip": "127.0.0.1", "port": 7085}
    assert boot["plugin_attr"]["prometheus"]["export_addr"] == {"ip": "127.0.0.1", "port": 9091}
    assert boot["plugin_attr"]["ai-proxy"]["http_client"] == "lua-resty-http"
    assert boot["nginx_config"]["envs"] == ["GW_KEY_WEBUI", "GW_KEY_LAB", "GW_KEY_AGENT"]
    assert boot["deployment"]["role_data_plane"]["config_provider"] == "json"
    assert boot["plugins"] == ["key-auth", "consumer-restriction", "mocking", "geniex-shape",
                               "ai-proxy-multi", "file-logger", "prometheus"]


def test_rendering_is_deterministic(tree):
    assert render_doc(tree)[1] == render_doc(tree)[1]


def test_apisix_json_is_rewritten_in_place(tree):
    out = tree / "out"
    _, files, _ = render_doc(tree)
    ra.write_bundle(files, str(out))
    inode = os.stat(out / "apisix.json").st_ino
    ra.write_bundle(files, str(out))
    assert os.stat(out / "apisix.json").st_ino == inode, "a rename strands the single-file bind mount"
    assert stat.S_IMODE(os.stat(out / "apisix.json").st_mode) == 0o644 or os.name == "nt"


def test_check_mode_finds_a_stale_bundle(tree):
    reg = write_doc(tree, fixture_doc())
    args = ["--registry", reg, "--prompts-dir", str(tree / "prompts"), "--out", str(tree / "out")]
    assert ra.main(args) == 0
    assert ra.main(args + ["--check"]) == 0
    with open(tree / "out" / "apisix.json", "a", encoding="utf-8") as fh:
        fh.write(" ")
    assert ra.main(args + ["--check"]) == 1


# --- what it refuses ------------------------------------------------------------------------

def _set(path, value):
    def edit(doc):
        node = doc
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = value
    return edit


def _del(path):
    def edit(doc):
        node = doc
        for key in path[:-1]:
            node = node[key]
        del node[path[-1]]
    return edit


R, L, G = ("serving", "routes"), ("serving", "lanes"), ("serving", "gateway")
REFUSALS = [
    (_set(R + ("chat", "lane"), "tpu"), "unknown lane"),
    (_set(L + ("npu", "backend"), "nope"), "is not in backends"),
    (_del(("backends", "g-gpu", "model")), "names no model"),
    (_set(("backends", "g-npu", "model"), "org/M-4B-GGUF:Q4_0"), "crashes the NPU server"),
    (_set(("backends", "g-gpu", "model"), "org/M-4B:W4A16"), "not a GGUF id"),
    (_set(R + ("chat", "budget_tokens"), 4096), "below the lane's context"),
    (_set(L + ("gpu", "context"), 4096), "larger context"),
    (_set(L + ("gpu", "timeout_s"), 1801), "timeout_s"),
    (_set(L + ("gpu", "timeout_s"), 0), "timeout_s"),
    (_set(L + ("gpu", "timeout_s"), True), "timeout_s"),
    (_set(R + ("raw-chat",), {"lane": "npu"}), "must not start with raw-"),
    (_set(R + ("chat-long", "budget_tokens"), 100), "needs an overflow_lane"),
    (_set(R + ("chat", "tools_prompt"), "other"), "not in serving.gateway.prompts"),
    (_set(G + ("consumers",), {"webui": "gw_key"}), "not an environment variable name"),
    (_set(G + ("consumers",), {"webui": "K", "lab": "K"}), "share one key variable"),
    (_set(G + ("lab_consumer",), "ops"), "is not a consumer"),
    (_set(G + ("listen",), "0.0.0.0:9080"), "localhost-only"),
    (_set(G + ("metrics_listen",), "127.0.0.1:9080"), "three different ports"),
    (_set(("backends", "g-cpu", "base_url"), "http://127.0.0.1:18184/v1"), "with no path"),
    (_set(G + ("prompts", "tools", "file"), "../tools.md"), "plain file name"),
    (_set(G + ("admin",), True), "unknown key"),
    (_set(L + ("npu", "ctx"), 4096), "unknown key"),
    (_del(G + ("drop_fields",)), "missing key"),
]


@pytest.mark.parametrize("edit, message", REFUSALS, ids=[m for _, m in REFUSALS])
def test_refuses(tree, edit, message):
    doc = copy.deepcopy(fixture_doc())
    edit(doc)
    with pytest.raises(ra.RenderError, match=message):
        render_doc(tree, doc)


def test_refuses_a_missing_or_changed_prompt(tree):
    (tree / "prompts" / "tools.md").write_bytes(PROMPT.replace(b"\r\n", b"\n"))
    with pytest.raises(ra.RenderError, match="the registry pins"):
        render_doc(tree)
    (tree / "prompts" / "tools.md").unlink()
    with pytest.raises(ra.RenderError, match="does not exist"):
        render_doc(tree)


def test_refuses_a_dollar_in_a_mocked_body():
    with pytest.raises(ra.RenderError, match="expanded by APISIX"):
        ra._mock("x", ["GET"], 200, {"a": "$remote_addr"}, uri="/x")


def test_main_reports_a_refusal_as_exit_1(tree, capsys):
    doc = fixture_doc()
    doc["serving"]["routes"]["chat"]["lane"] = "tpu"
    assert ra.main(["--registry", write_doc(tree, doc), "--prompts-dir", str(tree / "prompts")]) == 1
    assert "REFUSED" in capsys.readouterr().err


# --- the compose overlay ----------------------------------------------------------------

def overlay():
    return yaml.safe_load((STACK / "docker-compose.gateway.yml").read_text(encoding="utf-8"))


def test_the_overlay_pins_the_image_by_digest():
    image = overlay()["services"]["apisix"]["image"]
    assert image == ra.pinned_image(ra.DEFAULT_OVERLAY)
    assert image.startswith("docker.io/apache/apisix:") and len(image.split("@sha256:")[1]) == 64


def test_the_overlay_mounts_read_only_on_the_host_network():
    service = overlay()["services"]["apisix"]
    assert service["network_mode"] == "host" and "ports" not in service
    mounts = {v.split(":")[-2 if v.endswith(":ro") else -1]: v for v in service["volumes"]}
    for target in ("/usr/local/apisix/conf/config.yaml", "/usr/local/apisix/conf/apisix.json",
                   "/usr/local/apisix/custom"):
        assert mounts[target].endswith(":ro"), target
    assert service["environment"]["APISIX_STAND_ALONE"] == "true"


# --- serve-stack.sh, the parts that need no container -----------------------------------

linux_only = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="serve-stack.sh runs on Linux/WSL")


@linux_only
def test_serve_stack_usage():
    assert subprocess.run(["bash", str(SERVE), "--help"], capture_output=True, check=False).returncode == 0
    assert subprocess.run(["bash", str(SERVE), "bogus"], capture_output=True, check=False).returncode == 2


@linux_only
def test_serve_stack_keys_writes_distinct_private_keys(tmp_path):
    env = dict(os.environ, ANTFRASTRUCTURE_LLM_GATEWAY_DIR=str(tmp_path))
    first = subprocess.run(["bash", str(SERVE), "keys"], env=env, capture_output=True, text=True,
                           check=False)
    assert first.returncode == 0, first.stderr
    keys = dict(line.split("=", 1) for line in (tmp_path / "keys.env").read_text().splitlines())
    assert sorted(keys) == ["GW_KEY_AGENT", "GW_KEY_LAB", "GW_KEY_WEBUI"]
    assert len(set(keys.values())) == 3 and all(len(v) >= 32 for v in keys.values())
    assert stat.S_IMODE(os.stat(tmp_path / "keys.env").st_mode) == 0o600
    again = subprocess.run(["bash", str(SERVE), "keys"], env=env, capture_output=True, text=True,
                           check=False)
    assert "not rewritten" in again.stdout
