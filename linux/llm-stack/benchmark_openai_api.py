#!/usr/bin/env python3
"""Benchmark the Ollama OpenAI-compatible API with CPU and RAM tracking.

Uses the Glances REST API (included in the compose stack on port 61208)
for resource monitoring, with psutil as fallback on the host.

Usage:
    python linux/llm-stack/benchmark_openai_api.py
    python linux/llm-stack/benchmark_openai_api.py --model gemma4:26b --prompts 10
    python linux/llm-stack/benchmark_openai_api.py --output benchmark_results.json
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
GLANCES_URL = os.environ.get("GLANCES_URL", "http://localhost:61208")


def collect_hardware_info():
    """Collect system hardware info for reproducibility."""
    info = {}
    info["timestamp"] = datetime.now(timezone.utc).isoformat()

    # OS info
    try:
        import platform
        info["os"] = platform.system()
        info["os_release"] = platform.release()
        info["os_version"] = platform.version()
        info["architecture"] = platform.machine()
        info["processor"] = platform.processor()
    except Exception:
        pass

    # CPU info from /proc/cpuinfo (Linux)
    try:
        with open("/proc/cpuinfo") as f:
            cpuinfo = f.read()
        cpus = [p for p in cpuinfo.split("\n\n") if p.strip()]
        info["cpu_count"] = len(cpus)
        for line in cpus[0].split("\n") if cpus else []:
            if "model name" in line.lower():
                info["cpu_model"] = line.split(":")[1].strip()
                break
        # Total cores per CPU (core id max + 1)
        core_ids = set()
        for cpu in cpus:
            for line in cpu.split("\n"):
                if "core id" in line.lower():
                    core_ids.add(line.split(":")[1].strip())
        if core_ids:
            info["cpu_physical_cores"] = len(core_ids)
        # Thread(s) per core
        for line in cpus[0].split("\n") if cpus else []:
            if "siblings" in line.lower():
                info["cpu_threads_per_core"] = int(line.split(":")[1].strip())
                break
        info["cpu_total_threads"] = info["cpu_count"]
    except Exception:
        pass

    # RAM
    try:
        with open("/proc/meminfo") as f:
            mem = f.read()
        for line in mem.split("\n"):
            if line.startswith("MemTotal:"):
                info["ram_total_kb"] = int(line.split()[1])
                info["ram_total_gb"] = round(info["ram_total_kb"] / (1024**2), 1)
                break
    except Exception:
        pass

    # Container info via cgroup
    try:
        with open("/proc/1/cgroup") as f:
            cgroup = f.read()
        info["in_container"] = "docker" in cgroup or "containerd" in cgroup or len(cgroup.splitlines()) > 0
    except Exception:
        info["in_container"] = None

    # OLLAMA_HOST env
    info["ollama_host"] = os.environ.get("OLLAMA_HOST", "default")

    return info


# ── Prompts of varying length for realistic benchmarking ──────────────────────

SHORT_PROMPTS = [
    "What is 2+2?",
    "Say hello.",
    "What is the capital of France?",
    "Explain recursion in one sentence.",
    "What is an API?",
]

MEDIUM_PROMPTS = [
    "Write a Python function that computes the Fibonacci sequence using dynamic programming. Include a brief explanation of the time complexity.",
    "Explain the difference between REST and GraphQL APIs. When would you choose one over the other? Provide concrete examples.",
    "Write a bash script that monitors CPU and memory usage of a specific process every 5 seconds and logs the results to a CSV file.",
]

LONG_PROMPTS = [
    """Write a detailed technical blog post about building a production-ready LLM inference server. Cover the following aspects:
1. Model serving frameworks and their trade-offs (Ollama, vLLM, TGI, Triton Inference Server)
2. Hardware considerations: CPU vs GPU inference, memory requirements, quantization
3. API design: OpenAI-compatible endpoints, streaming, batching
4. Monitoring and observability: metrics to track, logging, alerting
5. Deployment strategies: Docker Compose, Kubernetes, auto-scaling
6. Security considerations: rate limiting, authentication, input sanitization

For each section, provide practical recommendations based on real-world production experience.""",
]


def get_glances_data(endpoint):
    """Fetch JSON data from the Glances REST API (v4, falling back to v3).

    Glances 4 (the latest-full image) serves /api/4 and dropped /api/3, so
    probe v4 first and fall back to v3 for older Glances containers.
    """
    import requests
    for api_ver in ("4", "3"):
        try:
            r = requests.get(f"{GLANCES_URL}/api/{api_ver}/{endpoint}", timeout=5)
            r.raise_for_status()
            return r.json()
        except Exception:
            continue
    return None


def sample_resources_psutil():
    """Sample CPU and RAM via psutil on the host."""
    import psutil
    cpu = psutil.cpu_percent(interval=0.1)
    mem = psutil.virtual_memory()
    return {
        "cpu_percent": cpu,
        "ram_percent": mem.percent,
        "ram_used_gb": mem.used / (1024 ** 3),
        "ram_total_gb": mem.total / (1024 ** 3),
    }


def sample_resources_glances():
    """Sample CPU and RAM via the Glances REST API."""
    cpu_data = get_glances_data("cpu")
    mem_data = get_glances_data("mem")
    if cpu_data is None or mem_data is None:
        return None
    return {
        "cpu_percent": cpu_data.get("total", 0.0),
        "ram_percent": mem_data.get("percent", 0.0),
        "ram_used_gb": mem_data.get("used", 0) / (1024 ** 3),
        "ram_total_gb": mem_data.get("total", 0) / (1024 ** 3),
    }


def detect_model_via_api():
    """Detect the currently loaded model via the Ollama API."""
    import requests
    try:
        # Ollama's show API is POST /api/show with a JSON body, not a GET path param.
        r = requests.post(f"{OLLAMA_BASE_URL}/api/show", json={"model": "gemma4:26b"}, timeout=5)
        if r.status_code == 200:
            return "gemma4:26b"
    except Exception:
        pass
    try:
        r = requests.get(f"{OLLAMA_BASE_URL}/v1/models", timeout=5)
        if r.status_code == 200:
            models = r.json().get("data", [])
            if models:
                return models[0]["id"]
    except Exception:
        pass
    return "unknown"


def benchmark_chat(
    model,
    prompts,
    *,
    max_tokens=256,
    temperature=0.0,
    stream=False,
    extra_params=None,
    sample_interval=0.2,
    warmup=True,
):
    """Run a benchmark against the OpenAI-compatible chat completions endpoint.

    Yields dicts with timing and resource data for each prompt.
    """
    import requests

    session = requests.Session()
    endpoint = f"{OLLAMA_BASE_URL}/v1/chat/completions"

    # Warmup: one short request to load the model into memory
    if warmup:
        try:
            wp_payload = {
                "model": model,
                "messages": [{"role": "user", "content": "Warmup"}],
                "max_tokens": 1,
            }
            if extra_params:
                wp_payload.update(extra_params)
            session.post(endpoint, json=wp_payload, timeout=120)
        except Exception:
            pass
        time.sleep(1)

    for i, prompt in enumerate(prompts):
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": stream,
        }
        if extra_params:
            payload.update(extra_params)
        # Request usage in streaming mode (Ollama supports this)
        if stream:
            payload["stream_options"] = {"include_usage": True}

        # Sample resources before request
        resources_before = sample_resources()
        start = time.monotonic()

        try:
            if stream:
                r = session.post(endpoint, json=payload, stream=True, timeout=300)
                r.raise_for_status()
                content_chunks = []
                usage = None
                for line in r.iter_lines(decode_unicode=True):
                    if line.startswith("data: "):
                        data = line[6:]
                        if data.strip() == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            # Usage in final streaming chunk (choices may be empty)
                            if "usage" in chunk:
                                usage = chunk["usage"]
                            choices = chunk.get("choices", [])
                            if not choices:
                                continue
                            delta = choices[0].get("delta", {})
                            content_chunks.append(delta.get("content", "") or delta.get("reasoning", ""))
                        except json.JSONDecodeError:
                            pass
                content = "".join(content_chunks)
            else:
                r = session.post(endpoint, json=payload, timeout=300)
                r.raise_for_status()
                body = r.json()
                content = body["choices"][0]["message"]["content"]
                usage = body.get("usage")
        except Exception as e:
            yield {
                "prompt_index": i,
                "prompt_preview": prompt[:60],
                "error": str(e),
                "latency_s": time.monotonic() - start,
            }
            continue

        elapsed = time.monotonic() - start
        resources_after = sample_resources()

        # Average resources during request
        avg_cpu = (
            (resources_before["cpu_percent"] + resources_after["cpu_percent"]) / 2
        )
        avg_ram_gb = (
            resources_before["ram_used_gb"] + resources_after["ram_used_gb"]
        ) / 2

        prompt_tokens = usage.get("prompt_tokens", 0) if usage else 0
        completion_tokens = usage.get("completion_tokens", 0) if usage else 0
        total_tokens = usage.get("total_tokens", 0) if usage else 0

        tokens_per_sec = completion_tokens / elapsed if elapsed > 0 else 0.0

        yield {
            "prompt_index": i,
            "prompt_preview": prompt[:60],
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total_tokens,
            "tokens_per_sec": round(tokens_per_sec, 2),
            "latency_s": round(elapsed, 2),
            "cpu_percent": round(avg_cpu, 1),
            "ram_used_gb": round(avg_ram_gb, 2),
            "content_preview": content[:80],
        }


_sampler_warned = False


def sample_resources():
    """Unified resource sampler: Glances API → psutil → zeros.

    Never raises: a broken sampler (missing psutil, flaky Glances, transient
    psutil read error) must not abort a multi-hour benchmark run. Failures
    degrade to zero readings with a single warning for the whole run.
    """
    global _sampler_warned
    try:
        result = sample_resources_glances()
        if result is not None:
            return result
        return sample_resources_psutil()
    except Exception as e:  # noqa: BLE001 — sampling is best-effort by design
        if not _sampler_warned:
            _sampler_warned = True
            print(f"  WARNING: resource sampling failed ({e!r}); "
                  "reporting zeros for CPU/RAM from now on", file=sys.stderr)
        return {"cpu_percent": 0.0, "ram_percent": 0.0, "ram_used_gb": 0.0, "ram_total_gb": 0.0}


def print_separator(char="━", width=80):
    print(char * width)


def print_table(results):
    """Print benchmark results as a formatted table."""
    if not results:
        print("No results to display.")
        return

    headers = ["#", "Prompt", "PT", "CT", "T/s", "Lat(s)", "CPU%", "RAM(GB)"]
    col_widths = [3, 50, 5, 5, 7, 8, 7, 8]

    def fmt_row(values):
        return "  ".join(
            f"{str(v)[:w]:{w}}{'':>1}" for v, w in zip(values, col_widths)
        )

    print_separator("─")
    print(fmt_row(headers))
    print_separator("─")

    for r in results:
        if "error" in r:
            print(f"  {r['prompt_index']:<3}  {r['prompt_preview'][:50]:<50}  ERROR: {r['error'][:40]}")
            continue
        print(fmt_row([
            r["prompt_index"],
            r["prompt_preview"][:50],
            r.get("prompt_tokens", "-"),
            r.get("completion_tokens", "-"),
            r.get("tokens_per_sec", "-"),
            r.get("latency_s", "-"),
            r.get("cpu_percent", "-"),
            r.get("ram_used_gb", "-"),
        ]))

    print_separator("─")
    print()

    latencies = [r["latency_s"] for r in results if "latency_s" in r and "error" not in r]
    tps_vals = [r["tokens_per_sec"] for r in results if "tokens_per_sec" in r and "error" not in r]
    cpu_vals = [r["cpu_percent"] for r in results if "cpu_percent" in r and "error" not in r]
    ram_vals = [r["ram_used_gb"] for r in results if "ram_used_gb" in r and "error" not in r]
    comp_tokens = [r["completion_tokens"] for r in results if "completion_tokens" in r and "error" not in r]
    total_tokens = [r["total_tokens"] for r in results if "total_tokens" in r and "error" not in r]

    if latencies:
        print(f"  Summary ({len(latencies)} requests):")
        print(f"    Latency:        {min(latencies):.2f}s  /  {sum(latencies)/len(latencies):.2f}s avg  /  {max(latencies):.2f}s max")
        print(f"    Tokens/sec:     {min(tps_vals):.1f}  /  {sum(tps_vals)/len(tps_vals):.1f} avg  /  {max(tps_vals):.1f} max")
        print(f"    CPU:            {min(cpu_vals):.1f}%  /  {sum(cpu_vals)/len(cpu_vals):.1f}% avg  /  {max(cpu_vals):.1f}% max")
        print(f"    RAM used:       {min(ram_vals):.2f}GB  /  {sum(ram_vals)/len(ram_vals):.2f}GB avg  /  {max(ram_vals):.2f}GB max")
        if comp_tokens and total_tokens:
            print(f"    Completion tok: {sum(comp_tokens)} total  /  {sum(comp_tokens)/len(comp_tokens):.1f} avg per req")
            total_elapsed = sum(latencies)
            print(f"    Overall:        {sum(total_tokens)} tokens in {total_elapsed:.1f}s  =  {sum(total_tokens)/total_elapsed:.1f} tok/s")


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark Ollama OpenAI-compatible API with CPU/RAM tracking",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--model", default=None, help="Model name (auto-detected if omitted)")
    parser.add_argument("--prompts", type=int, default=0, help="Number of prompts (0 = all)")
    parser.add_argument("--max-tokens", type=int, default=256, help="Max tokens per response")
    parser.add_argument("--temperature", type=float, default=0.0, help="Sampling temperature")
    parser.add_argument("--stream", action="store_true", help="Use streaming responses")
    parser.add_argument("--output", default=None, help="Write results as JSON to this file")
    parser.add_argument("--no-warmup", action="store_true", help="Skip warmup request")
    parser.add_argument("--extra-params", default=None,
                        help='Extra JSON params for the request body (e.g. \'{"num_ctx":16000,"repeat_penalty":1.1}\')')
    parser.add_argument("--load", default=None, help="Load and re-display results from a JSON file")

    args = parser.parse_args()

    if args.load:
        with open(args.load) as f:
            data = json.load(f)
        print(f"\n  Loaded benchmark results from {args.load}")
        print(f"  Model: {data.get('model', '?')}  |  Date: {data.get('timestamp', '?')}")
        print()
        print_table(data.get("results", []))
        return

    model = args.model or detect_model_via_api()
    print(f"\n  Model: {model}")
    print(f"  API:   {OLLAMA_BASE_URL}/v1")
    print(f"  Glances: {GLANCES_URL}/api/4 (v3 fallback)")
    print()

    # Build the prompt list
    all_prompts = SHORT_PROMPTS + MEDIUM_PROMPTS + LONG_PROMPTS
    if args.prompts > 0:
        all_prompts = all_prompts[: args.prompts]

    print(f"  Running {len(all_prompts)} benchmark prompts (max_tokens={args.max_tokens}, stream={args.stream})")
    print()

    extra_params = json.loads(args.extra_params) if args.extra_params else None

    # Incremental persistence: every completed result is appended to a JSONL
    # side file so a crash or Ctrl-C never discards finished measurements.
    # The side file uses a .jsonl suffix on purpose — run_benchmarks.sh and
    # the viewer manifest only glob *.json, so it can never be mistaken for
    # a finished result file.
    partial_path = f"{args.output}.partial.jsonl" if args.output else None
    if partial_path and os.path.exists(partial_path):
        os.remove(partial_path)  # stale leftover from an aborted run

    results = []
    interrupted = False
    try:
        for result in benchmark_chat(
            model,
            all_prompts,
            max_tokens=args.max_tokens,
            temperature=args.temperature,
            stream=args.stream,
            extra_params=extra_params,
            warmup=not args.no_warmup,
        ):
            results.append(result)
            if partial_path:
                with open(partial_path, "a") as pf:
                    pf.write(json.dumps(result) + "\n")
    except KeyboardInterrupt:
        interrupted = True
        print(f"\n  Interrupted — {len(results)}/{len(all_prompts)} prompts completed.")
        if partial_path:
            print(f"  Completed results preserved in {partial_path}")

    print_table(results)

    output = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": model,
        "api_url": f"{OLLAMA_BASE_URL}/v1",
        "hardware": collect_hardware_info(),
        "config": {
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "stream": args.stream,
            "extra_params": extra_params,
            "prompts_requested": len(all_prompts),
            "prompts_completed": len([r for r in results if "error" not in r]),
        },
        "results": results,
    }

    if args.output and not interrupted:
        # Atomic write: never leave a truncated/half-written JSON behind for
        # run_benchmarks.sh's summary loop or the viewer manifest to choke on.
        tmp_path = f"{args.output}.tmp"
        with open(tmp_path, "w") as f:
            json.dump(output, f, indent=2)
        os.replace(tmp_path, args.output)
        if partial_path and os.path.exists(partial_path):
            os.remove(partial_path)
        print(f"\n  Results written to {args.output}")

    if interrupted:
        sys.exit(130)


if __name__ == "__main__":
    main()
