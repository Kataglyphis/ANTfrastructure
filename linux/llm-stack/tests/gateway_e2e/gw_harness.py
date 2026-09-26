"""The gateway under test: a fixture registry and prompt, serve-stack.sh, and request helpers."""
import hashlib
import json
import os
import secrets
import shutil
import socket
import subprocess

from gw_client import LogTail, call

HERE = os.path.dirname(os.path.abspath(__file__))
STACK = os.path.dirname(os.path.dirname(HERE))
SERVE = os.path.join(STACK, "scripts", "serve-stack.sh")

# CRLF on purpose, like the prompt P8.1 measured: the pin covers the raw bytes.
PROMPT = (b"Tool disambiguation (e2e fixture).\r\n"
          b"Call the tool whose name matches the request; never guess arguments.\r\n") * 4
LANE_MODELS = {"npu": "qualcomm/Fake-4B-Instruct:W4A16", "gpu": "fake/Fake-4B-Instruct-GGUF:Q4_0",
               "cpu": "fake/Fake-9B-Distill-GGUF:Q4_K_M"}
# Scaled down from 300/1800/1800 s; cpu keeps 1800 s so a route above the stock cap must load.
TIMEOUTS = {"npu": 2, "gpu": 6, "cpu": 1800}
CONTEXT = {"npu": 4096, "gpu": 16384, "cpu": 16384}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def registry(lanes, ports, budget=3900, listen=None):
    backends = {f"e2e-{n}": {"base_url": f"http://127.0.0.1:{lane.port}", "model": LANE_MODELS[n]}
                for n, lane in lanes.items()}
    gateway = {
        "listen": listen or f"127.0.0.1:{ports[0]}", "status_listen": f"127.0.0.1:{ports[1]}",
        "metrics_listen": f"127.0.0.1:{ports[2]}",
        "consumers": {"webui": "GW_KEY_WEBUI", "lab": "GW_KEY_LAB", "agent": "GW_KEY_AGENT"},
        "lab_consumer": "lab", "estimate": {"bytes_per_token": 3.0, "default_reserve": 1024},
        "drop_fields": ["power_mode"], "raw_routes": True,
        "prompts": {"tool-disambiguation": {"file": "tools.md",
                                            "sha256": hashlib.sha256(PROMPT).hexdigest()}}}
    lane_conf = {n: {"backend": f"e2e-{n}", "format": "qairt" if n == "npu" else "gguf",
                     "context": CONTEXT[n], "timeout_s": TIMEOUTS[n], "t0_rewrite": n != "npu"}
                 for n in lanes}
    routes = {"chat": {"lane": "npu", "overflow_lane": "gpu", "budget_tokens": budget,
                       "tools_prompt": "tool-disambiguation"},
              "chat-long": {"lane": "gpu"}, "agent": {"lane": "cpu"}}
    return {"default": "e2e-npu", "backends": backends,
            "serving": {"gateway": gateway, "lanes": lane_conf, "routes": routes}}


class Gateway:
    def __init__(self, root, lanes):
        self.lanes = lanes
        self.lanes_models = dict(LANE_MODELS)
        self.root = root
        self.ports = [free_port() for _ in range(3)]
        self.port = self.ports[0]
        self.metrics_port = self.ports[2]
        self.state = os.path.join(root, "state")
        self.registry_path = os.path.join(root, "backends.json")
        prompts = os.path.join(root, "prompts")
        os.makedirs(prompts)
        with open(os.path.join(prompts, "tools.md"), "wb") as fh:
            fh.write(PROMPT)
        self.keys = {c: secrets.token_hex(16) for c in ("webui", "lab", "agent")}
        self.env = dict(os.environ, ANTFRASTRUCTURE_LLM_GATEWAY_DIR=self.state,
                        ANTFRASTRUCTURE_LLM_BACKENDS=self.registry_path,
                        ANTFRASTRUCTURE_LLM_PROMPTS_DIR=prompts,
                        ANTFRASTRUCTURE_LLM_GATEWAY_PROJECT=f"gw-e2e-{os.getpid()}",
                        **{f"GW_KEY_{c.upper()}": k for c, k in self.keys.items()})
        self.write_registry()
        self.log = LogTail(os.path.join(self.state, "logs", "requests.jsonl"))

    def write_registry(self, **kw):
        with open(self.registry_path, "w", encoding="utf-8") as fh:
            json.dump(registry(self.lanes, self.ports, **kw), fh, indent=1)

    def serve(self, *args, timeout=300):
        return subprocess.run(["bash", SERVE, *args], env=self.env, capture_output=True,
                              text=True, timeout=timeout, check=False)

    def live(self, name):
        with open(os.path.join(self.state, "live", name), encoding="utf-8") as fh:
            return json.load(fh)

    def info(self):
        return call(self.port, "/gateway/info", method="GET").json()

    def route(self, rid):
        return next(r for r in self.live("apisix.json")["routes"] if r["id"] == rid)

    def post(self, model, key="lab", path="/v1/chat/completions", fake=None, **body):
        body.setdefault("messages", [{"role": "user", "content": "hi"}])
        body = {k: v for k, v in body.items() if v is not None}
        headers = {f"X-Fake-{lane.capitalize()}": d for lane, d in (fake or {}).items()}
        return call(self.port, path, dict(body, model=model), key=self.keys.get(key, key),
                    headers=headers)

    def exec(self, *cmd):
        """Run a command inside the live gateway container (not a validation one)."""
        engine = os.environ.get("ANTFRASTRUCTURE_LLM_ENGINE") or next(
            n for n in ("nerdctl", "docker") if shutil.which(n))
        project = self.env["ANTFRASTRUCTURE_LLM_GATEWAY_PROJECT"]
        names = subprocess.run([engine, "ps", "--format", "{{.Names}}"], capture_output=True,
                               text=True, check=True).stdout.split()
        (name,) = [n for n in names if n.startswith(project) and "-validate-" not in n]
        return subprocess.run([engine, "exec", name, *cmd], capture_output=True, text=True,
                              check=True).stdout

    def requests(self, lane):
        return self.lanes[lane].completions()

    def counts(self):
        return {n: len(lane.completions()) for n, lane in self.lanes.items()}
