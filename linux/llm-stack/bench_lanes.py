#!/usr/bin/env python3
"""Concurrency benchmarks across one or more serving endpoints (LB4 + LB5).

Two questions the single-endpoint sweep cannot answer:

LB5 --batching: does ONE server overlap concurrent requests?
    Fire two requests at the same endpoint simultaneously. If the second one's
    first token arrives only after the first request has fully finished, the
    server serialises and has no continuous batching -- so extra throughput
    must come from more servers, not more clients. (Measured on GenieX: the
    second request waited 27.6 s, exactly the duration of the first, and the
    server would not even answer /v1/models meanwhile.)

LB4 --lanes: do several servers ADD UP, or fight each other?
    Drive N endpoints at once and report per-lane plus aggregate throughput.
    Compute units differ wildly here: on one Snapdragon host the NPU and GPU
    lanes cost each other ~1-3 % (19.25 + 12.11 = 31.4 tok/s) while a CPU lane
    and a GPU lane contend for the same cores. None of that is derivable from
    sequential single-endpoint runs.

Usage:
    # does this server batch?
    python3 bench_lanes.py --batching --backend ollama

    # do these lanes add up?  (names come from backends.json)
    python3 bench_lanes.py --lanes geniex-npu geniex-cpu

    # ...or spell an endpoint out in full
    python3 bench_lanes.py --lanes \
        npu=http://127.0.0.1:18181,model=qualcomm/Qwen3-4B-Instruct-2507:W4A16
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.request

DEFAULT_PROMPT = ("Write a Python function that merges two sorted lists. "
                  "Explain briefly.")


def stream_once(base_url, model, prompt, max_tokens=256, timeout=900):
    """One streaming request. Returns timing dict (never raises)."""
    body = json.dumps({
        "model": model, "stream": True, "max_tokens": max_tokens,
        "temperature": 0, "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"})

    started = time.monotonic()
    ttft = None
    tokens = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                # The space after "data:" is optional per the SSE spec.
                if not line.startswith("data:"):
                    continue
                payload = line[5:].lstrip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices") or []
                if choices and (choices[0].get("delta", {}).get("content")):
                    if ttft is None:
                        ttft = time.monotonic() - started
                    tokens += 1
    except Exception as e:  # noqa: BLE001 — a dead lane must not kill the run
        return {"error": f"{type(e).__name__}: {e}", "wall_s": time.monotonic() - started}

    wall = time.monotonic() - started
    decode_window = wall - (ttft or 0)
    return {
        "ttft_s": round(ttft, 3) if ttft is not None else None,
        "tokens": tokens,
        "wall_s": round(wall, 2),
        "decode_tok_per_sec": round((tokens - 1) / decode_window, 2)
        if decode_window > 0 and tokens > 1 else 0.0,
    }


def run_parallel(jobs):
    """Run (label, fn) jobs at the same time; return {label: result}."""
    out = {}
    lock = threading.Lock()

    def work(label, fn):
        result = fn()
        with lock:
            out[label] = result

    threads = [threading.Thread(target=work, args=(lbl, fn)) for lbl, fn in jobs]
    wall_start = time.monotonic()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return out, time.monotonic() - wall_start


def probe_batching(base_url, model, prompt, max_tokens):
    """LB5 — decide whether one endpoint overlaps two concurrent requests."""
    print(f"\n  Batching probe: two concurrent requests to {base_url}")
    results, wall = run_parallel([
        (f"req{i}", (lambda: stream_once(base_url, model, prompt, max_tokens)))
        for i in range(2)
    ])

    bad = [k for k, v in results.items() if "error" in v]
    if bad:
        for k in bad:
            print(f"    {k}: ERROR {results[k]['error']}")
        return None

    ordered = sorted(results.values(), key=lambda r: r["ttft_s"] or 0)
    first, second = ordered[0], ordered[1]
    for name, r in sorted(results.items()):
        print(f"    {name}: ttft={r['ttft_s']:6.2f}s  {r['decode_tok_per_sec']:6.2f} tok/s  "
              f"wall={r['wall_s']:6.2f}s")

    # If the later request only started producing after the earlier one had
    # essentially finished, the server ran them one after another.
    serialised = (second["ttft_s"] or 0) >= first["wall_s"] * 0.8
    verdict = "SERIALISED (no batching)" if serialised else "OVERLAPPED (batching)"
    print(f"    wall for both: {wall:.2f}s")
    print(f"    VERDICT: {verdict}")
    if serialised:
        print("    -> extra throughput needs MORE SERVERS, not more clients.")
    return {"verdict": verdict, "serialised": serialised,
            "wall_s": round(wall, 2), "requests": results}


def run_lanes(lanes, prompt, max_tokens, sequential_baseline=True):
    """LB4 — per-lane and aggregate throughput when lanes run together."""
    report = {"lanes": {}, "baseline": {}}

    if sequential_baseline:
        print("\n  Baseline — each lane alone:")
        for name, (url, model) in lanes.items():
            r = stream_once(url, model, prompt, max_tokens)
            report["baseline"][name] = r
            if "error" in r:
                print(f"    {name:10s} ERROR {r['error']}")
            else:
                print(f"    {name:10s} {r['decode_tok_per_sec']:6.2f} tok/s   "
                      f"ttft={r['ttft_s']:6.2f}s")

    print("\n  Together — all lanes at once:")
    results, wall = run_parallel([
        (name, (lambda u=url, m=model: stream_once(u, m, prompt, max_tokens)))
        for name, (url, model) in lanes.items()
    ])
    report["lanes"] = results

    total = 0.0
    for name in lanes:
        r = results[name]
        if "error" in r:
            print(f"    {name:10s} ERROR {r['error']}")
            continue
        total += r["decode_tok_per_sec"]
        base = report["baseline"].get(name, {}).get("decode_tok_per_sec")
        delta = ""
        if base:
            change = 100 * (r["decode_tok_per_sec"] - base) / base
            delta = f"   ({change:+.0f}% vs alone)"
        print(f"    {name:10s} {r['decode_tok_per_sec']:6.2f} tok/s   "
              f"ttft={r['ttft_s']:6.2f}s{delta}")

    best_alone = max((v.get("decode_tok_per_sec", 0)
                      for v in report["baseline"].values()), default=0)
    print(f"\n    AGGREGATE: {total:.1f} tok/s across {len(lanes)} lanes "
          f"(wall {wall:.1f}s)")
    if best_alone:
        print(f"    Best single lane alone: {best_alone:.1f} tok/s "
              f"-> {total / best_alone:.2f}x by running lanes together")
    print("    NOTE: aggregate only materialises with that many CONCURRENT "
          "requests.\n          One agent waiting for one answer still sees a "
          "single lane's speed.")
    report["aggregate_tok_per_sec"] = round(total, 2)
    report["wall_s"] = round(wall, 2)
    return report


def parse_lane(spec):
    """Parse 'name=URL,model=MODEL' into (name, url, model)."""
    try:
        head, model_part = spec.split(",model=", 1)
        name, url = head.split("=", 1)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"bad lane {spec!r}; expected name=URL,model=MODEL")
    return name.strip(), url.strip().rstrip("/"), model_part.strip()


def resolve_lane(spec):
    """Accept either a full 'name=URL,model=MODEL' spec or a bare backend name.

    Naming a backend is the common case -- `--lanes geniex-npu geniex-cpu`
    reads far better than two URLs, and keeps the endpoints in one place
    (backends.json) instead of scattered across shell history.
    """
    if "=" in spec:
        return parse_lane(spec)

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from benchmark_openai_api import load_backends

    backends, _ = load_backends()
    if spec not in backends:
        known = ", ".join(sorted(backends)) or "(none configured)"
        raise argparse.ArgumentTypeError(
            f"unknown backend {spec!r}. Known: {known}. "
            "Or give a full spec: name=URL,model=MODEL")
    entry = backends[spec]
    model = entry.get("model")
    if not model:
        raise argparse.ArgumentTypeError(
            f"backend {spec!r} has no default model in backends.json; "
            f"use {spec}={entry['base_url']},model=<model> instead")
    return spec, entry["base_url"].rstrip("/"), model


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--batching", action="store_true",
                    help="LB5: does one endpoint overlap concurrent requests?")
    ap.add_argument("--lanes", nargs="+", metavar="BACKEND|name=URL,model=MODEL",
                    help="LB4: drive these endpoints simultaneously. Either a "
                         "backend name from backends.json (e.g. geniex-npu) or "
                         "a full name=URL,model=MODEL spec.")
    ap.add_argument("--endpoint", default=None,
                    help="Endpoint URL for --batching (overrides --backend)")
    ap.add_argument("--backend", default=None,
                    help="Named backend from backends.json for --batching")
    ap.add_argument("--model", default=None, help="Model for --batching")
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--no-baseline", action="store_true",
                    help="Skip the one-lane-at-a-time baseline")
    ap.add_argument("--output", default=None, help="Write the report as JSON")
    args = ap.parse_args()

    if not args.batching and not args.lanes:
        ap.error("nothing to do: pass --batching and/or --lanes")

    report = {"prompt": args.prompt, "max_tokens": args.max_tokens}

    if args.batching:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from benchmark_openai_api import detect_model_via_api, resolve_backend

        url, backend_model, source = resolve_backend(args.backend, args.endpoint)
        model = args.model or backend_model or detect_model_via_api(url)
        print(f"  Endpoint: {url}  (from {source})")
        report["batching"] = probe_batching(url, model, args.prompt, args.max_tokens)

    if args.lanes:
        lanes = {}
        for spec in args.lanes:
            name, url, model = resolve_lane(spec)
            lanes[name] = (url, model)
        report["lane_run"] = run_lanes(
            lanes, args.prompt, args.max_tokens,
            sequential_baseline=not args.no_baseline)

    print()
    if args.output:
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  Report written to {args.output}")


if __name__ == "__main__":
    main()
