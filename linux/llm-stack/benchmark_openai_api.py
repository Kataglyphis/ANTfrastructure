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
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
GLANCES_URL = os.environ.get("GLANCES_URL", "http://localhost:61208")

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
    """Fetch JSON data from the Glances REST API."""
    import requests
    try:
        r = requests.get(f"{GLANCES_URL}/api/3/{endpoint}", timeout=5)
        r.raise_for_status()
        return r.json()
    except Exception:
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


def get_container_stats(container_name="llm-stack-ollama-1"):
    """Get CPU/RAM for a specific container via `nerdctl stats` or `docker stats`."""
    for cmd in (["nerdctl", "stats"], ["docker", "stats"]):
        try:
            result = subprocess.run(
                [*cmd, "--no-stream", "--no-trunc", container_name],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode != 0:
                continue
            lines = result.stdout.strip().split("\n")
            if len(lines) < 2:
                continue
            parts = [p for p in lines[1].split() if p]
            if len(parts) >= 14:
                cpu = parts[2].rstrip("%")
                mem_pct = parts[6].rstrip("%")
                mem_used = parts[5]  # e.g., "7.123GiB" or "7.123GiB"
                return {
                    "cpu_percent": float(cpu),
                    "ram_percent": float(mem_pct),
                    "ram_used": mem_used,
                }
        except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
            continue
    return None


def detect_model_via_api():
    """Detect the currently loaded model via the Ollama API."""
    import requests
    try:
        r = requests.get(f"{OLLAMA_BASE_URL}/api/show/gemma4:26b", timeout=5)
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
            session.post(
                endpoint,
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": "Warmup"}],
                    "max_tokens": 1,
                },
                timeout=120,
            )
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

        # Sample resources before request
        resources_before = sample_resources()
        start = time.monotonic()

        try:
            if stream:
                r = session.post(endpoint, json=payload, stream=True, timeout=300)
                r.raise_for_status()
                content_chunks = []
                for line in r.iter_lines(decode_unicode=True):
                    if line.startswith("data: "):
                        data = line[6:]
                        if data.strip() == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            delta = chunk.get("choices", [{}])[0].get("delta", {})
                            content_chunks.append(delta.get("content", ""))
                        except json.JSONDecodeError:
                            pass
                content = "".join(content_chunks)
                usage = None
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


def sample_resources():
    """Unified resource sampler: Glances API → psutil → empty."""
    result = sample_resources_glances()
    if result is not None:
        return result
    try:
        return sample_resources_psutil()
    except ImportError:
        return {"cpu_percent": 0.0, "ram_percent": 0.0, "ram_used_gb": 0.0, "ram_total_gb": 0.0}


def print_separator(char="━", width=80):
    print(char * width)


def print_table(results, show_all=False):
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
    print(f"  Glances: {GLANCES_URL}/api/3")
    print()

    # Build the prompt list
    all_prompts = SHORT_PROMPTS + MEDIUM_PROMPTS + LONG_PROMPTS
    if args.prompts > 0:
        all_prompts = all_prompts[: args.prompts]

    print(f"  Running {len(all_prompts)} benchmark prompts (max_tokens={args.max_tokens}, stream={args.stream})")
    print()

    results = list(
        benchmark_chat(
            model,
            all_prompts,
            max_tokens=args.max_tokens,
            temperature=args.temperature,
            stream=args.stream,
            warmup=not args.no_warmup,
        )
    )

    print_table(results)

    output = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": model,
        "api_url": f"{OLLAMA_BASE_URL}/v1",
        "config": {
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "stream": args.stream,
            "prompts_requested": len(all_prompts),
            "prompts_completed": len([r for r in results if "error" not in r]),
        },
        "results": results,
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
        print(f"\n  Results written to {args.output}")


if __name__ == "__main__":
    main()
