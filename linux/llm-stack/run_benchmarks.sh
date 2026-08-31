#!/usr/bin/env bash
set -euo pipefail

# Run benchmarks across multiple num_ctx and max_tokens configs.
# Uses the existing benchmark_openai_api.py with Ollama extra params
# passed via extra_body (supported by Ollama's OAI-compatible endpoint).

cd "$(dirname "$0")"

# Same default as the compose ollama service's OLLAMA_PULL_MODELS — override
# BOTH with one env var: BENCH_MODEL=<model> (compose pulls it, this benches it).
MODEL="${BENCH_MODEL:-gemma4:26b}"

# Which serving backend to sweep. Names come from backends.json; 'ollama' (this
# stack's own compose service) is the default. BENCH_BACKEND=geniex-npu points
# the same sweep at the Snapdragon lane without editing anything.
BACKEND="${BENCH_BACKEND:-ollama}"
BACKEND_ARGS=(--backend "$BACKEND")
API_URL="$(python3 -c "
import sys; sys.path.insert(0, '.')
from benchmark_openai_api import resolve_backend
print(resolve_backend('$BACKEND')[0])
")/v1"
OUTDIR="./benchmark_results"
mkdir -p "$OUTDIR"

# Configs to test:  (num_ctx x max_tokens)
CONFIGS=(
  "8192:256"      # baseline
  "16000:256"     # user asked about this
  "8192:4096"     # baseline + long gen
  "16000:4096"    # long ctx + long gen
  "32768:4096"    # pushing further
)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LLM Config Benchmark Suite"
echo "  Backend: $BACKEND"
echo "  Model:   $MODEL"
echo "  API:     $API_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Health gate (LB1) ─────────────────────────────────────────────────────
# A broken model is FAST: the throughput numbers below would look great while
# the output is nonsense. Check the model answers correctly before spending
# hours measuring how quickly it does so. Set BENCH_SKIP_CORRECTNESS=1 to
# bypass (e.g. benchmarking a model the probe's prompts do not suit).
if [[ "${BENCH_SKIP_CORRECTNESS:-0}" != "1" ]]; then
  echo "▸ Health gate: verifiable-answer probe"
  set +e
  python3 benchmark_openai_api.py "${BACKEND_ARGS[@]}" --model "$MODEL" --correctness-only
  gate_rc=$?
  set -e
  case "$gate_rc" in
    0) echo "  → model answers correctly; proceeding" ;;
    2) echo ""
       echo "  NOTE: the probe ran out of tokens before the model finished"
       echo "  answering. That is a measurement limit, not a model fault —"
       echo "  raise --correctness-max-tokens if you want a clean verdict." ;;
    *) echo ""
       echo "  WARNING: the model got at least one verifiable answer WRONG."
       echo "  Speed numbers from a broken model are meaningless — inspect the"
       echo "  GGUF first (python3 inspect_gguf.py <file>); sub-4-bit i-quants"
       echo "  are broken on some runtimes. Continuing anyway." ;;
  esac
  echo ""
  echo "──────────────────────────────────────────────────────"
  echo ""
fi

for cfg in "${CONFIGS[@]}"; do
  NUM_CTX="${cfg%%:*}"
  MAX_TOKENS="${cfg##*:}"
  OUTFILE="$OUTDIR/ctx${NUM_CTX}_tok${MAX_TOKENS}.json"

  echo "▸ Config: num_ctx=$NUM_CTX  max_tokens=$MAX_TOKENS"
  echo "  Output: $OUTFILE"
  echo ""

  python3 benchmark_openai_api.py \
    "${BACKEND_ARGS[@]}" \
    --model "$MODEL" \
    --max-tokens "$MAX_TOKENS" \
    --temperature 0.0 \
    --stream \
    --prompts 8 \
    --extra-params "{\"num_ctx\":$NUM_CTX}" \
    --output "$OUTFILE"

  # brief summary
  python3 -c "
import json
with open('$OUTFILE') as f:
    d = json.load(f)
results = [r for r in d['results'] if 'error' not in r]
if results:
    tps = [r['tokens_per_sec'] for r in results]
    lats = [r['latency_s'] for r in results]
    cpu = [r['cpu_percent'] for r in results]
    ram = [r['ram_used_gb'] for r in results]
    ttfts = [r['ttft_s'] for r in results if r.get('ttft_s') is not None]
    extra = f'  TTFT: {sum(ttfts)/len(ttfts):.2f}s avg' if ttfts else ''
    print(f'  → T/s: {sum(tps)/len(tps):.1f} avg  '
          f'Answer: {sum(lats)/len(lats):.1f}s avg  '
          f'CPU: {sum(cpu)/len(cpu):.1f}%  '
          f'RAM: {sum(ram)/len(ram):.1f}GB' + extra)
else:
    print(f'  → No successful results')
" 2>&1

  echo ""
  echo "──────────────────────────────────────────────────────"
  echo ""
done

# ── Generate manifest for the React viewer ────────────────────────────────
MANIFEST="$OUTDIR/_manifest.json"
python3 -c "
import json, os, glob

results_dir = '$OUTDIR'
manifest = {
    'title': 'LLM Benchmark — $MODEL',
    'generated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'model': '$MODEL',
    'host_hardware': {},
    'configs': [],
}

for fname in sorted(glob.glob(os.path.join(results_dir, '*.json'))):
    if os.path.basename(fname).startswith('_'):
        continue
    with open(fname) as f:
        d = json.load(f)
    # Take hardware info from first result
    if d.get('hardware') and not manifest['host_hardware']:
        manifest['host_hardware'] = d['hardware']
    config = {
        'label': os.path.basename(fname).replace('.json', ''),
        'file': os.path.basename(fname),
        'config': d.get('config', {}),
        'correctness': d.get('correctness'),
        'results': d.get('results', []),
    }
    manifest['configs'].append(config)

with open('$MANIFEST', 'w') as f:
    json.dump(manifest, f, indent=2)
print(f'  Manifest: $MANIFEST ({len(manifest[\"configs\"])} configs)')
" 2>&1

echo ""
echo "All benchmarks complete. Results in $OUTDIR/"
echo ""
echo "Quick comparison:"
python3 -c "
import json, os
results_dir = '$OUTDIR'
for fname in sorted(os.listdir(results_dir)):
    # Skip non-result files — including our own _manifest.json (no 'results'
    # key; sorts FIRST, so without this guard the KeyError killed the whole
    # comparison under set -e at the end of every multi-hour run). Mirrors the
    # startswith('_') guard the manifest loop above already has.
    if not fname.endswith('.json') or fname.startswith('_'):
        continue
    with open(os.path.join(results_dir, fname)) as f:
        d = json.load(f)
    results = [r for r in d.get('results', []) if 'error' not in r]
    if not results:
        continue
    tps = [r['tokens_per_sec'] for r in results]
    lats = [r['latency_s'] for r in results]
    cpu = [r['cpu_percent'] for r in results]
    ram = [r['ram_used_gb'] for r in results]
    ct = sum(r.get('completion_tokens', 0) for r in results)
    pt = sum(r.get('prompt_tokens', 0) for r in results)
    name = fname.replace('.json','')
    ttfts = [r['ttft_s'] for r in results if r.get('ttft_s') is not None]
    ttft_s = f'{sum(ttfts)/len(ttfts):5.2f}s' if ttfts else '    -'
    print(f'  {name:25s}  '
          f'T/s: {sum(tps)/len(tps):5.1f}  '
          f'TTFT: {ttft_s}  '
          f'Answer: {sum(lats)/len(lats):5.1f}s  '
          f'CPU: {sum(cpu)/len(cpu):5.1f}%  '
          f'RAM: {sum(ram)/len(ram):5.1f}GB  '
          f'CT: {ct:4d}  PT: {pt:4d}')
" 2>&1
