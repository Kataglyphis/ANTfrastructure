#!/usr/bin/env python3
"""Render the llm-stack gateway (APISIX) from backends.json's `serving` block.

Strict: an unknown lane, backend or key, a missing prompt, a prompt whose raw
bytes do not match their pinned sha256, a non-loopback listener and similar
mistakes stop the render instead of producing a config APISIX would half-load.
What it emits and why: linux/llm-stack/README.md § Gateway. Stdlib only.
"""
import argparse
import base64
import copy
import hashlib
import json
import os
import re
import string
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STACK = os.path.dirname(HERE)
DEFAULT_REGISTRY = os.path.join(STACK, "backends.json")
DEFAULT_OVERLAY = os.path.join(STACK, "docker-compose.gateway.yml")
TEMPLATE = os.path.join(HERE, "config.template.yaml")
LUA_DIR = os.path.join(HERE, "lua")
LUA_FILES = ("geniex_hook.lua", "apisix/plugins/geniex-shape.lua")
PROMPTS_ENV = "ANTFRASTRUCTURE_LLM_PROMPTS_DIR"

AI_URIS = ["/v1/chat/completions", "/v1/completions"]
MAX_TIMEOUT_S = 1800
LOG_FILE = "/var/log/gateway/requests.jsonl"
LANE_AUTH = {"header": {"Authorization": "Bearer unused"}}
KEY_AUTH = {"header": "Authorization", "hide_credentials": True}

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
CONSUMER_RE = re.compile(r"^[a-z][a-z0-9_]{0,40}$")
VAR_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ENDPOINT_RE = re.compile(r"^http://([A-Za-z0-9.-]+):(\d{1,5})/?$")
LOOPBACK_RE = re.compile(r"^127\.0\.0\.1:(\d{1,5})$")
IMAGE_RE = re.compile(r"^\s*image:\s*[\"']?(\S*apisix\S*@sha256:[0-9a-f]{64})[\"']?\s*$",
                      re.MULTILINE)

GATEWAY_KEYS = {"listen", "status_listen", "metrics_listen", "consumers", "lab_consumer",
                "estimate", "drop_fields", "prompts", "raw_routes"}
LANE_KEYS = {"backend", "format", "context", "timeout_s", "t0_rewrite"}
ROUTE_KEYS = {"lane", "overflow_lane", "budget_tokens", "tools_prompt"}
SERVING_KEYS = {"gateway", "lanes", "routes"}

LOG_FORMAT = {
    "ts": "$time_iso8601", "consumer": "$consumer_name", "alias": "$request_llm_model",
    "lane": "$gw_lane", "rerouted": "$gw_rerouted", "prompt": "$gw_prompt",
    "est_tokens": "$gw_est", "status": "$status", "upstream": "$upstream_addr",
    "upstream_status": "$upstream_status", "model": "$llm_model",
    "prompt_tokens": "$llm_prompt_tokens", "completion_tokens": "$llm_completion_tokens",
    "ttft_ms": "$llm_time_to_first_token", "upstream_ms": "$apisix_upstream_response_time",
    "request_s": "$request_time", "stream": "$llm_stream", "tools": "$llm_tool_count",
    "tool_calls": "$llm_has_tool_calls", "aborted": "$gw_stream_aborted",
    "method": "$request_method", "uri": "$uri",
}


class RenderError(Exception):
    """The registry, a prompt or the overlay is not something this renderer vouches for."""


def need(cond, msg):
    if not cond:
        raise RenderError(msg)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _keys(obj, allowed, where, required=()):
    need(isinstance(obj, dict), f"{where} must be a JSON object")
    extra = sorted(k for k in obj if k not in allowed and not k.startswith("_"))
    need(not extra, f"{where}: unknown key(s) {extra} (allowed: {sorted(allowed)})")
    missing = sorted(k for k in required if k not in obj)
    need(not missing, f"{where}: missing key(s) {missing}")


def _loopback(addr, where):
    m = LOOPBACK_RE.match(str(addr))
    need(m is not None and 0 < int(m.group(1)) < 65536,
         f"{where} must be 127.0.0.1:<port> (the gateway is localhost-only), got {addr!r}")
    return {"ip": "127.0.0.1", "port": int(m.group(1))}


def parse_consumers(consumers, lab):
    need(isinstance(consumers, dict) and consumers, "serving.gateway.consumers must name at least one client")
    for name, var in consumers.items():
        need(CONSUMER_RE.match(name), f"consumer name {name!r} must match {CONSUMER_RE.pattern}")
        need(isinstance(var, str) and VAR_RE.match(var),
             f"consumer {name}: {var!r} is not an environment variable name")
    need(len(set(consumers.values())) == len(consumers), "two consumers share one key variable")
    need(lab in consumers, f"serving.gateway.lab_consumer {lab!r} is not a consumer")
    return dict(consumers)


def parse_prompts(prompts):
    need(isinstance(prompts, dict), "serving.gateway.prompts must be an object")
    out = {}
    for name, spec in prompts.items():
        where = f"serving.gateway.prompts.{name}"
        need(NAME_RE.match(name), f"{where}: name must match {NAME_RE.pattern}")
        _keys(spec, {"file", "sha256"}, where, required=("file", "sha256"))
        need(isinstance(spec["file"], str) and FILE_RE.match(spec["file"]),
             f"{where}: file must be a plain file name inside the prompts directory")
        need(isinstance(spec["sha256"], str) and SHA_RE.match(spec["sha256"]),
             f"{where}: sha256 must be 64 lowercase hex digits")
        out[name] = {"file": spec["file"], "sha256": spec["sha256"]}
    return out


def parse_gateway(gw):
    where = "serving.gateway"
    _keys(gw, GATEWAY_KEYS, where, required=GATEWAY_KEYS - {"raw_routes"})
    out = {name: _loopback(gw[name], f"{where}.{name}")
           for name in ("listen", "status_listen", "metrics_listen")}
    ports = {out[k]["port"] for k in out}
    need(len(ports) == 3, f"{where}: listen, status_listen and metrics_listen need three different ports")
    est = gw["estimate"]
    _keys(est, {"bytes_per_token", "default_reserve"}, f"{where}.estimate",
          required=("bytes_per_token", "default_reserve"))
    need(_is_number(est["bytes_per_token"]) and est["bytes_per_token"] >= 0.5,
         f"{where}.estimate.bytes_per_token must be a number >= 0.5")
    need(isinstance(est["default_reserve"], int) and not isinstance(est["default_reserve"], bool)
         and est["default_reserve"] >= 0, f"{where}.estimate.default_reserve must be an integer >= 0")
    drop = gw["drop_fields"]
    need(isinstance(drop, list) and all(isinstance(f, str) and f for f in drop),
         f"{where}.drop_fields must be a list of field names")
    need(isinstance(gw.get("raw_routes", False), bool), f"{where}.raw_routes must be true or false")
    out.update(consumers=parse_consumers(gw["consumers"], gw["lab_consumer"]),
               lab_consumer=gw["lab_consumer"], estimate=dict(est), drop_fields=list(drop),
               prompts=parse_prompts(gw["prompts"]), raw_routes=gw.get("raw_routes", False))
    return out


def _endpoint(url, where):
    m = ENDPOINT_RE.match(url if isinstance(url, str) else "")
    need(m is not None, f"{where}: base_url must be http://<host>:<port> with no path, got {url!r}")
    return f"http://{m.group(1)}:{m.group(2)}"


def parse_lane(name, lane, backends):
    where = f"serving.lanes.{name}"
    need(NAME_RE.match(name) and not name.startswith("raw-"), f"{where}: bad lane name")
    _keys(lane, LANE_KEYS, where, required=LANE_KEYS)
    entry = backends.get(lane["backend"])
    need(isinstance(entry, dict), f"{where}: backend {lane['backend']!r} is not in backends")
    model = entry.get("model")
    need(isinstance(model, str) and model, f"{where}: backend {lane['backend']!r} names no model")
    need(lane["format"] in ("qairt", "gguf"), f"{where}: format must be qairt or gguf")
    is_gguf = "gguf" in model.lower()
    need(not (lane["format"] == "qairt" and is_gguf),
         f"{where}: {model} is a GGUF; loading one into a QAIRT lane crashes the NPU server")
    need(lane["format"] == "qairt" or is_gguf, f"{where}: format gguf but {model} is not a GGUF id")
    need(isinstance(lane["context"], int) and not isinstance(lane["context"], bool)
         and lane["context"] > 0, f"{where}: context must be a positive integer")
    t = lane["timeout_s"]
    need(_is_number(t) and 0 < t <= MAX_TIMEOUT_S, f"{where}: timeout_s must be in (0, {MAX_TIMEOUT_S}]")
    need(isinstance(lane["t0_rewrite"], bool), f"{where}: t0_rewrite must be true or false")
    return {"name": name, "model": model, "endpoint": _endpoint(entry.get("base_url"), where),
            "context": lane["context"], "timeout_ms": round(t * 1000),
            "t0_rewrite": lane["t0_rewrite"]}


def parse_route(alias, route, lanes, prompts):
    where = f"serving.routes.{alias}"
    need(NAME_RE.match(alias) and not alias.startswith("raw-"),
         f"{where}: an alias must match {NAME_RE.pattern} and must not start with raw-")
    _keys(route, ROUTE_KEYS, where, required=("lane",))
    need(route["lane"] in lanes, f"{where}: unknown lane {route['lane']!r} (lanes: {sorted(lanes)})")
    out = {"alias": alias, "lane": route["lane"], "overflow_lane": None, "budget": None,
           "prompt": route.get("tools_prompt")}
    over = route.get("overflow_lane")
    if over is None:
        need("budget_tokens" not in route, f"{where}: budget_tokens needs an overflow_lane")
    else:
        need(over in lanes, f"{where}: unknown overflow_lane {over!r} (lanes: {sorted(lanes)})")
        primary = lanes[route["lane"]]["context"]
        need(lanes[over]["context"] > primary,
             f"{where}: overflow_lane {over} must have a larger context than lane {route['lane']}")
        budget = route.get("budget_tokens")
        need(isinstance(budget, int) and not isinstance(budget, bool) and 0 < budget < primary,
             f"{where}: budget_tokens must be a positive integer below the lane's context ({primary})")
        out.update(overflow_lane=over, budget=budget)
    need(out["prompt"] is None or out["prompt"] in prompts,
         f"{where}: tools_prompt {out['prompt']!r} is not in serving.gateway.prompts")
    return out


def parse_serving(doc):
    """Validate the whole serving block; needs no prompt file and no network."""
    need(isinstance(doc, dict), "the registry must be a JSON object")
    backends = doc.get("backends")
    need(isinstance(backends, dict), "the registry has no backends object")
    serving = doc.get("serving")
    need(isinstance(serving, dict), "the registry has no serving block")
    _keys(serving, SERVING_KEYS, "serving", required=SERVING_KEYS)
    gateway = parse_gateway(serving["gateway"])
    need(isinstance(serving["lanes"], dict) and serving["lanes"], "serving.lanes must name at least one lane")
    lanes = {n: parse_lane(n, v, backends) for n, v in serving["lanes"].items() if not n.startswith("_")}
    own = {gateway[k]["port"] for k in ("listen", "status_listen", "metrics_listen")}
    for name, lane in lanes.items():
        host, port = lane["endpoint"][len("http://"):].rsplit(":", 1)
        loopback = host == "localhost" or host == "0.0.0.0" or host.startswith("127.")
        need(not (loopback and int(port) in own),
             f"serving.lanes.{name}: {lane['endpoint']} is the gateway's own listener; "
             f"a lane is a GenieX server, never a lab-* entry")
    need(isinstance(serving["routes"], dict), "serving.routes must be an object")
    routes = [parse_route(a, r, lanes, gateway["prompts"])
              for a, r in serving["routes"].items() if not a.startswith("_")]
    need(routes, "serving.routes must name at least one alias")
    return {"gateway": gateway, "lanes": lanes, "routes": routes}


def load_prompts(prompts, prompts_dir):
    """Read every pinned prompt as raw bytes and check it against its pin."""
    out = {}
    for name, spec in prompts.items():
        need(prompts_dir, f"prompt {name!r} is pinned but no prompts directory was given "
                          f"(--prompts-dir or {PROMPTS_ENV})")
        path = os.path.join(prompts_dir, spec["file"])
        need(os.path.isfile(path), f"prompt {name!r}: {path} does not exist")
        with open(path, "rb") as fh:
            raw = fh.read()
        got = sha256_hex(raw)
        need(got == spec["sha256"],
             f"prompt {name!r}: {path} has sha256 {got}, the registry pins {spec['sha256']} "
             f"(the pin covers the raw bytes, line endings included)")
        out[name] = raw
    return out


def pinned_image(overlay):
    with open(overlay, encoding="utf-8") as fh:
        found = IMAGE_RE.findall(fh.read())
    need(len(found) == 1, f"{overlay}: expected exactly one apisix image pinned by digest, found {found}")
    return found[0]


def _instance(lane, priority):
    return {"name": lane["name"], "provider": "openai-compatible", "priority": priority,
            "weight": 1, "auth": copy.deepcopy(LANE_AUTH), "options": {"model": lane["model"]},
            "override": {"endpoint": lane["endpoint"]}}


def _policy(lane, shaped, relabel=False):
    return {"timeout_ms": lane["timeout_ms"], "t0_rewrite": bool(shaped and lane["t0_rewrite"]),
            "overflow_relabel": relabel}


def _fallback_window(timeout_ms):
    """Failures slower than this go to the client: a timed-out lane is never retried."""
    return max(1, timeout_ms - min(1000, timeout_ms // 10))


def _proxy(ordered):
    conf = {"instances": [_instance(lane, prio) for lane, prio in ordered],
            "timeout": max(lane["timeout_ms"] for lane, _ in ordered),
            "keepalive": False, "streaming_flush_interval_ms": 0}
    if len(ordered) > 1:
        conf.update(fallback_strategy=["http_5xx"], max_retries=1,
                    retry_on_failure_within_ms=_fallback_window(ordered[0][0]["timeout_ms"]))
    return conf


def _ai_route(rid, model, priority, extra_vars, shape, proxy, restrict=None):
    plugins = {"key-auth": dict(KEY_AUTH), "geniex-shape": shape, "ai-proxy-multi": proxy}
    if restrict:
        plugins["consumer-restriction"] = {"whitelist": [restrict]}
    return {"id": rid, "name": rid, "uris": list(AI_URIS), "methods": ["POST"], "priority": priority,
            "vars": [["post_arg.model", "==", model]] + extra_vars, "plugins": plugins}


def alias_routes(route, lanes, gateway, prompts):
    lane, alias = lanes[route["lane"]], route["alias"]
    over = lanes[route["overflow_lane"]] if route["overflow_lane"] else None
    shape = {"primary": lane["name"], "tag": "no", "drop_fields": list(gateway["drop_fields"]),
             "estimate": over is not None,
             "lanes": {lane["name"]: _policy(lane, True, relabel=over is not None)}}
    if route["prompt"]:
        raw = prompts[route["prompt"]]
        shape["tools_prompt"] = {"name": route["prompt"], "sha256": sha256_hex(raw),
                                 "b64": base64.b64encode(raw).decode("ascii")}
    out = []
    ordered = [(lane, 1)]
    if over:
        shape["lanes"][over["name"]] = _policy(over, True)
        presend = dict(shape, primary=over["name"], tag="presend",
                       lanes={over["name"]: _policy(over, True)})
        out.append(_ai_route(f"{alias}-presend", alias, 30, [["gw_est_tokens", ">", route["budget"]]],
                             presend, _proxy([(over, 0)])))
        ordered.append((over, 0))
    out.append(_ai_route(alias, alias, 20, [], shape, _proxy(ordered)))
    return out


def raw_route(lane, lab):
    shape = {"primary": lane["name"], "tag": "no", "drop_fields": [], "estimate": False,
             "lanes": {lane["name"]: _policy(lane, False)}}
    rid = f"raw-{lane['name']}"
    return _ai_route(rid, rid, 20, [], shape, _proxy([(lane, 0)]), restrict=lab)


def _mock(rid, methods, status, body, uris=None, uri=None, priority=0):
    text = canonical(body)
    need("$" not in text, f"route {rid}: a '$' in a mocked body would be expanded by APISIX")
    route = {"id": rid, "name": rid, "methods": methods, "priority": priority,
             "plugins": {"mocking": {"response_status": status, "content_type": "application/json",
                                     "with_mock_header": False, "response_example": text}}}
    if uris:
        route["uris"] = list(uris)
    else:
        route["uri"] = uri
    return route


def static_routes(aliases):
    models = {"object": "list", "data": [{"id": a, "object": "model", "created": 0,
                                           "owned_by": "llm-gateway"} for a in aliases]}
    unknown = {"error": {"message": "unknown model; this gateway serves " + ", ".join(aliases),
                         "type": "invalid_request_error", "param": "model", "code": "model_not_found"}}
    return [_mock("models", ["GET"], 200, models, uri="/v1/models"),
            _mock("unknown-model", ["POST"], 404, unknown, uris=AI_URIS)]


def build_document(serving, prompts):
    gw, lanes = serving["gateway"], serving["lanes"]
    routes = []
    for route in serving["routes"]:
        routes.extend(alias_routes(route, lanes, gw, prompts))
    if gw["raw_routes"]:
        routes.extend(raw_route(lane, gw["lab_consumer"]) for lane in lanes.values())
    routes.extend(static_routes([r["alias"] for r in serving["routes"]]))
    prompt_bytes = {r["alias"]: len(prompts[r["prompt"]]) for r in serving["routes"] if r["prompt"]}
    meta = dict(gw["estimate"], id="geniex-shape", prompt_bytes=prompt_bytes)
    consumers = [{"username": name, "plugins": {"key-auth": {"key": "Bearer ${{" + var + "}}"}}}
                 for name, var in gw["consumers"].items()]
    rules = [{"id": "observe", "plugins": {
        "prometheus": {"prefer_name": True},
        "file-logger": {"path": LOG_FILE, "log_format": dict(LOG_FORMAT)}}}]
    return {"consumers": consumers, "global_rules": rules, "plugin_metadata": [meta], "routes": routes}


def render_boot_config(gateway):
    with open(TEMPLATE, encoding="utf-8") as fh:
        tpl = string.Template(fh.read())
    return tpl.substitute(
        listen_ip=gateway["listen"]["ip"], listen_port=gateway["listen"]["port"],
        status_ip=gateway["status_listen"]["ip"], status_port=gateway["status_listen"]["port"],
        metrics_ip=gateway["metrics_listen"]["ip"], metrics_port=gateway["metrics_listen"]["port"],
        key_vars="[" + ", ".join(gateway["consumers"].values()) + "]")


def read_lua():
    out = {}
    for rel in LUA_FILES:
        with open(os.path.join(LUA_DIR, rel), "rb") as fh:
            out[rel] = fh.read()
    return out


def render(registry, prompts_dir, overlay):
    """Everything the gateway mounts, plus render.json (what /gateway/info reports)."""
    with open(registry, "rb") as fh:
        doc = json.loads(fh.read().decode("utf-8"))
    serving = parse_serving(doc)
    prompts = load_prompts(serving["gateway"]["prompts"], prompts_dir)
    document = build_document(serving, prompts)
    boot = render_boot_config(serving["gateway"]).encode("utf-8")
    lua = read_lua()
    image = pinned_image(overlay)
    restart = {"image": image, "boot_config_sha256": sha256_hex(boot),
               "lua_sha256": {k: sha256_hex(v) for k, v in sorted(lua.items())}}
    info = dict(restart, config_sha256=sha256_hex(canonical(document).encode("ascii")),
                restart_sha256=sha256_hex(canonical(restart).encode("ascii")),
                registry_sha256=sha256_hex(canonical(doc).encode("ascii")),
                prompts_sha256={n: sha256_hex(b) for n, b in sorted(prompts.items())})
    document["routes"].insert(0, _mock("gateway-info", ["GET"], 200, info, uri="/gateway/info"))
    ids = [r["id"] for r in document["routes"]]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    # APISIX keeps the last item of a repeated id and logs nothing: a silent half-load.
    need(not dupes, f"route id(s) {dupes} would be emitted twice; rename the alias")
    gw = serving["gateway"]
    meta = dict(info, key_vars=list(gw["consumers"].values()),
                listen=f"{gw['listen']['ip']}:{gw['listen']['port']}",
                status_listen=f"{gw['status_listen']['ip']}:{gw['status_listen']['port']}")
    files = {"apisix.json": (json.dumps(document, indent=1, sort_keys=True) + "\n").encode("ascii"),
             "config.yaml": boot,
             "render.json": (json.dumps(meta, indent=1, sort_keys=True) + "\n").encode("ascii")}
    files.update({"lua/" + rel: data for rel, data in lua.items()})
    return files, meta


def write_in_place(path, data):
    """Truncate and rewrite: a rename would leave a single-file bind mount on the old inode."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "r+b" if os.path.exists(path) else "wb") as fh:
        fh.seek(0)
        fh.write(data)
        fh.truncate()
    os.chmod(path, 0o644)


def write_bundle(files, out_dir):
    for rel, data in sorted(files.items()):
        write_in_place(os.path.join(out_dir, *rel.split("/")), data)
    for root, dirs, _ in os.walk(out_dir):
        for d in dirs:
            os.chmod(os.path.join(root, d), 0o755)
    os.chmod(out_dir, 0o755)


def stale_files(files, out_dir):
    stale = []
    for rel, data in sorted(files.items()):
        path = os.path.join(out_dir, *rel.split("/"))
        if not os.path.isfile(path):
            stale.append(rel)
            continue
        with open(path, "rb") as fh:
            if fh.read() != data:
                stale.append(rel)
    return stale


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--registry", default=DEFAULT_REGISTRY, help="backends.json with a serving block")
    ap.add_argument("--prompts-dir", default=os.environ.get(PROMPTS_ENV),
                    help=f"directory holding the pinned prompt files (default: ${PROMPTS_ENV})")
    ap.add_argument("--overlay", default=DEFAULT_OVERLAY, help="compose overlay that pins the image")
    ap.add_argument("--out", help="write the bundle here (apisix.json is rewritten in place)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="render in memory; with --out, exit 1 when the files there are stale")
    mode.add_argument("--print-image", action="store_true", help="print the pinned image and exit")
    mode.add_argument("--print-key-vars", action="store_true",
                      help="print the consumers' key variable names and exit (needs no prompt)")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.print_image:
            print(pinned_image(args.overlay))
            return 0
        if args.print_key_vars:
            with open(args.registry, "rb") as fh:
                serving = parse_serving(json.loads(fh.read().decode("utf-8")))
            print("\n".join(serving["gateway"]["consumers"].values()))
            return 0
        files, meta = render(args.registry, args.prompts_dir, args.overlay)
    except (RenderError, OSError, ValueError) as exc:
        print(f"render_apisix: REFUSED: {exc}", file=sys.stderr)
        return 1
    if args.check and args.out:
        stale = stale_files(files, args.out)
        print(f"config_sha256={meta['config_sha256']}")
        if stale:
            print(f"render_apisix: STALE in {args.out}: {', '.join(stale)}", file=sys.stderr)
            return 1
        return 0
    if args.out and not args.check:
        write_bundle(files, args.out)
    print(f"config_sha256={meta['config_sha256']}")
    print(f"restart_sha256={meta['restart_sha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
