#!/usr/bin/env bash
# bench-history.py on synthetic results of all four formats and a replayed Actions API; no real GitHub call, artifact-store error or runner timing; arguments select sections (-k fetch).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${here}/test-harness.sh"
tool="${here}/../bench-history.py"
actions="${here}/../../../.github/actions"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# bh <args...>: the tool's stdout, stderr and status land in ${work}/out, err and rc.
bh() { python3 "${tool}" "$@" > "${work}/out" 2> "${work}/err"; echo "$?" > "${work}/rc"; }

# criterion <dir> <detector ns> <draw_box ns>: Criterion's layout for two benches.
criterion() {
  mkdir -p "$1/detector/new" "$1/frame/draw_box/new"
  printf '{"mean":{"point_estimate":%s}}\n' "$2" > "$1/detector/new/estimates.json"
  printf '{"mean":{"point_estimate":%s}}\n' "$3" > "$1/frame/draw_box/new/estimates.json"
}

gated='{"detector":{"direction":"lower","gate":true},"*":{"direction":"lower"}}'
# crit <fixture> <history> [args...]: a criterion report with the gated declaration.
crit() { bh report --format criterion --metrics "${gated}" --result "${work}/$1" --history "${work}/$2" "${@:3}"; }
# _refused <case> <format> <result> [args...]: a report on that result under ${work} must exit 2.
_refused() {
  bh report --format "$2" --result "${work}/$3" "${@:4}"
  t_case "$1"
  t_assert_grep "${work}/rc" '^2$'
}

_section_criterion() {
  mkdir -p "${work}/history" "${work}/two"
  printf '{"detector": 50000000, "frame/draw_box": 1000}\n' > "${work}/history/1.json"
  printf '{"detector": 54000000, "frame/draw_box": 1100}\n' > "${work}/history/2.json"
  printf '{"detector": 52000000, "frame/draw_box": 900}\n' > "${work}/history/3.json"
  cp "${work}/history/1.json" "${work}/history/2.json" "${work}/two/"
  criterion "${work}/slower" 70000000 1000
  criterion "${work}/double" 104000000 1000
  criterion "${work}/tiny" 52000000 5000

  crit slower history --key c --write "${work}/rec.json"
  t_case "criterion: the mean against the median of earlier results"
  t_assert_grep "${work}/out" '^\| `detector` \| 70\.00 ms \| \+34\.6 % \(median 52\.00 ms of 3\) \|$'
  t_case "a slowdown over the warning threshold warns and passes"
  t_assert_grep "${work}/err" '^::warning title=Benchmark slower::detector \+34\.6 % against the median of 3 runs$'
  t_assert_grep "${work}/rc" '^0$'
  t_case "the stored record names its verdict and metrics"
  t_assert_grep "${work}/rec.json" '"verdict": "ok"'
  t_assert_grep "${work}/rec.json" '"detector": 70000000'

  crit double history --write "${work}/failed.json"
  t_case "exactly a doubling of a gated lower-is-better metric fails"
  t_assert_grep "${work}/rc" '^1$'
  t_assert_grep "${work}/err" '^::error title=Benchmark far slower::detector \+100\.0 %'
  t_assert_grep "${work}/out" '^Far slower than before: detector \+100\.0 %\.$'
  t_case "a failed run is stored as failed, and an earlier failed record is no yardstick"
  t_assert_grep "${work}/failed.json" '"verdict": "failed"'
  cp "${work}/failed.json" "${work}/two/9.json"
  crit double two
  t_assert_grep "${work}/out" 'median 52\.00 ms of 2\)'

  t_case "below three earlier results a doubling only warns"
  t_assert_grep "${work}/rc" '^0$'
  t_assert_grep "${work}/err" '^::warning title=Benchmark history short::detector: 2 earlier result\(s\), a doubling fails from 3$'

  crit tiny history
  t_case "an ungated metric five times slower warns and passes"
  t_assert_grep "${work}/rc" '^0$'
  t_assert_grep "${work}/err" '^::warning title=Benchmark slower::frame/draw_box \+400\.0 %'

  bh report --metrics '{"frame/*":{"direction":"lower"}}' --format criterion --history "${work}/history" --result "${work}/slower"
  t_case "an undeclared metric is shown and never judged"
  t_assert_no_grep "${work}/err" 'detector'
  t_assert_grep "${work}/out" '^\| `detector` \| 70\.00 ms \| \+34\.6 % \(median 52\.00 ms of 3\) \|$'

  crit slower missing
  t_case "no history yet says so"
  t_assert_grep "${work}/out" '^\| `detector` \| 70\.00 ms \| no history yet \|$'
}

_section_formats() {
  # The other three formats' fixtures, raw earlier results among them.
  python3 - "${work}" <<'PY'
import json
import pathlib
import sys

w = pathlib.Path(sys.argv[1])
def put(name, doc):
    (w / name).parent.mkdir(parents=True, exist_ok=True)
    (w / name).write_text(json.dumps(doc))
def gb(name, t, unit, **extra):
    return {"name": name, "run_name": name.split("/")[0], "run_type": "iteration", "real_time": t, "time_unit": unit, **extra}
put("gbench.json", {"context": {}, "benchmarks": [
    gb("BM_DetectFrame", 2.0, "ms", frames_per_second=500.0),
    gb("BM_TextGenerateTiny", 30.0, "us", items_per_second=33000.0),
    gb("BM_Broken", 1.0, "ns", error_occurred=True, error_message="no model")]})
for i in (1, 2, 3):
    put(f"ghist/{i}.json", {"benchmarks": [gb("BM_DetectFrame", 1.0, "ms", frames_per_second=1100.0)]})
    put(f"fhist/{i}.json", {"start": {"frame_count": 3, "average_frame_build_time_millis": 10.0}})
put("agg.json", {"benchmarks": [gb("BM_PreprocessFrame/repeats:3", 9.0, "us"),
    {**gb("BM_PreprocessFrame", 7.0, "us"), "run_type": "aggregate", "aggregate_name": "mean"},
    {**gb("BM_PreprocessFrame", 5.0, "us"), "run_type": "aggregate", "aggregate_name": "median"}]})
put("frames.json", {"start": {"frame_count": 3, "average_frame_build_time_millis": 25.0, "missed_frame_build_budget_count": 1}})
put("orch.json", {"benchmark": "orchestrant-hot-paths", "reports": [{"label": "detector_decode", "p50_ms": 2.5, "p95_ms": 4.0, "min_ms": 1.0}]})
PY
  bh report --format google-benchmark --result "${work}/gbench.json" --history "${work}/ghist" \
    --metrics '{"BM_DetectFrame":{"direction":"lower","gate":true},"*/frames_per_second":{"direction":"higher","gate":true}}'
  t_case "google-benchmark: real time in its time unit, and raw earlier results as history"
  t_assert_grep "${work}/out" '^\| Benchmark \| Time \| Change against earlier runs \|$'
  t_assert_grep "${work}/out" '^\| `BM_TextGenerateTiny` \| 30\.00 µs \| no history yet \|$'
  t_case "a user counter is a metric of its own"
  t_assert_grep "${work}/out" '^\| `BM_TextGenerateTiny/items_per_second` \| 33000\.0 \|'
  t_case "a benchmark that errored is no result"
  t_assert_no_grep "${work}/out" 'BM_Broken'
  t_case "a gated time that doubled and a higher-is-better counter that halved both fail"
  t_assert_grep "${work}/rc" '^1$'
  t_assert_grep "${work}/out" '^Far slower than before: BM_DetectFrame \+100\.0 %\.$'
  t_assert_grep "${work}/out" '^Far lower than before: BM_DetectFrame/frames_per_second -54\.5 %\.$'
  t_assert_grep "${work}/err" '^::error title=Benchmark far worse::BM_DetectFrame/frames_per_second'

  bh report --format google-benchmark --result "${work}/agg.json"
  t_case "repetitions are read through their median aggregate"
  t_assert_grep "${work}/out" '^\| `BM_PreprocessFrame` \| 5\.00 µs \| no history yet \|$'

  bh report --format flutter-frame --result "${work}/frames.json" --history "${work}/fhist" \
    --metrics '{"*/average_frame_build_time_millis":{"direction":"lower","gate":true},"*_millis":{"direction":"lower"}}'
  t_case "flutter-frame: <scenario>/<key> metrics, earlier raw timings as history"
  t_assert_grep "${work}/out" '^\| `start/average_frame_build_time_millis` \| 25\.0 \| \+150\.0 % \(median 10\.0 of 3\) \|$'
  t_assert_grep "${work}/rc" '^1$'

  bh report --format orchestrant-bench --result "${work}/orch.json"
  t_case "orchestrant-bench: p50 and p95 per label, nothing else"
  t_assert_grep "${work}/out" '^\| `detector_decode/p50_ms` \| 2\.50 ms \| no history yet \|$'
  t_assert_grep "${work}/out" '^\| `detector_decode/p95_ms` \| 4\.00 ms \|'
  t_assert_no_grep "${work}/out" 'min_ms'
}

_section_inputs() {
  criterion "${work}/slower" 70000000 1000
  printf '{"benchmarks": []}\n' > "${work}/none.json"
  : > "${work}/empty.json"
  mkdir -p "${work}/nothing"

  _refused "a missing result file fails" orchestrant-bench absent.json
  t_assert_grep "${work}/err" '^::error title=Benchmark result missing::'
  _refused "an empty result file fails" google-benchmark empty.json
  _refused "a result without one metric fails" google-benchmark none.json
  _refused "an empty Criterion directory fails" criterion nothing
  _refused "a declaration without a direction fails" criterion slower --metrics '{"detector":{"direction":"up"}}'
}

# The Actions API replayed through a fake gh: weekly records, some expired, plus noise that must not count.
_fake_actions_api() {
  fake="${work}/fake"
  mkdir -p "${fake}/bin" "${fake}/api" "${fake}/runs" "${fake}/fail"
  cat > "${fake}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH}/calls"
case "$1 $2" in
  "api -X") f="${FAKE_GH}/api/$(printf '%s' "$4" | tr '/?&=' '____').json"
            if [ -f "$f" ]; then cat "$f"; else echo "HTTP 403: $4" >&2; exit 1; fi ;;
  "run download") left="$(cat "${FAKE_GH}/fail/$3" 2>/dev/null || echo 0)"
                  if [ "${left}" -gt 0 ]; then echo "$((left - 1))" > "${FAKE_GH}/fail/$3"; echo "HTTP 503: run $3" >&2; exit 1; fi
                  mkdir -p "$9" && cp "${FAKE_GH}/runs/$3/"* "$9/" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${fake}/bin/gh"
  python3 - "${fake}" <<'EOF'
import datetime
import json
import pathlib
import sys

fake = pathlib.Path(sys.argv[1])
start = datetime.datetime(2026, 1, 5, 6, tzinfo=datetime.UTC)
rows = []
for week in range(20):
    run = 1000 + week
    created = (start + datetime.timedelta(days=7 * week)).isoformat().replace("+00:00", "Z")
    rows.append({"name": "bench-history-k", "created_at": created, "expired": week < 7,
                 "workflow_run": {"id": run, "head_branch": "develop"}})
    (fake / "runs" / str(run)).mkdir(parents=True)
    value = 10.0 + week * week
    (fake / "runs" / str(run) / "bench-history-k.json").write_text(json.dumps(
        {"schema_version": 1, "verdict": "ok", "metrics": {"x/p50_ms": value}}))
rows.append({"name": "bench-history-k", "created_at": "2026-05-30T00:00:00Z", "expired": False,
             "workflow_run": {"id": 2000, "head_branch": "feature"}})
rows.append({"name": "bench-history-k", "created_at": "2026-05-31T00:00:00Z", "expired": False,
             "workflow_run": {"id": 4242, "head_branch": "develop"}})
page1 = rows[:10] + [{"name": "bench-history-k", "created_at": "2026-01-01T00:00:00Z", "expired": False,
                      "workflow_run": {"id": 3000 + i, "head_branch": "pr"}} for i in range(90)]
api = fake / "api"
(api / "repos_o_r_actions_artifacts_name_bench-history-k_per_page_100_page_1.json").write_text(json.dumps({"artifacts": page1}))
(api / "repos_o_r_actions_artifacts_name_bench-history-k_per_page_100_page_2.json").write_text(json.dumps({"artifacts": rows[10:]}))
(api / "repos_o_r.json").write_text(json.dumps({"default_branch": "develop"}))
EOF
  # fetched <args...>: bh's fetch against the fake API, as run 4242 of o/r.
  fetched() { PATH="${fake}/bin:${PATH}" FAKE_GH="${fake}" GH_TOKEN=t GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=4242 bh fetch "$@"; }
}

_section_fetch() {
  _fake_actions_api
  fetched --key k --dest "${work}/weekly"
  t_case "a weekly series is read across two API pages, back to the oldest unexpired week"
  t_assert_grep "${work}/rc" '^0$'
  t_assert_grep "${work}/out" '^bench-history: read 13 earlier result\(s\) of bench-history-k on develop$'
  t_assert_eq 13 "$(find "${work}/weekly" -name '*.json' | wc -l | tr -d ' ')"
  t_case "the default branch comes from the repository when none is passed"
  t_assert_grep "${fake}/calls" '^api -X GET repos/o/r$'
  t_case "this run, other branches and expired weeks stay out"
  t_assert_no_grep "${fake}/calls" 'download (4242|2000|100[0-6]) '
  printf '{"benchmark": "b", "reports": [{"label": "x", "p50_ms": 1.0}]}\n' > "${work}/weekly-now.json"
  bh report --format orchestrant-bench --result "${work}/weekly-now.json" --history "${work}/weekly" --metrics '{"*":{"direction":"lower","gate":true}}'
  t_case "the stored records span weeks 8 to 20 and their median is the yardstick"
  t_assert_grep "${work}/out" '^\| `x/p50_ms` \| 1\.00 ms \| -99\.4 % \(median 179\.00 ms of 13\) \|$'

  fetched --key k --keep 4 --branch develop --dest "${work}/four"
  t_case "--keep takes the newest records"
  t_assert_eq "1016 1017 1018 1019" "$(find "${work}/four" -name '*.json' | sed 's/.*-//; s/\.json$//' | sort | tr '\n' ' ' | sed 's/ $//')"

  fetched --key gone --branch develop --dest "${work}/gone"
  t_case "an API refusal fails instead of reading as an empty history"
  t_assert_grep "${work}/rc" '^2$'
  t_assert_grep "${work}/err" '^::error title=Benchmark history unreadable::.*HTTP 403'
}

_section_fetch_failures() {
  _fake_actions_api
  # ${fake}/fail/<run> holds how many more downloads of that run the fake store refuses.
  echo 1 > "${fake}/fail/1019"
  echo 99 > "${fake}/fail/1018"
  : > "${fake}/calls"
  fetched --key k --keep 4 --branch develop --retry-pause 0 --dest "${work}/flaky"
  t_case "a download that fails once is tried again, and its record is read"
  t_assert_eq 2 "$(grep -c -e 'download 1019 ' "${fake}/calls")"
  t_assert_eq "1016 1017 1019" "$(find "${work}/flaky" -name '*.json' | sed 's/.*-//; s/\.json$//' | sort | tr '\n' ' ' | sed 's/ $//')"
  t_case "a download that fails every time is left out after three tries, and the step goes on"
  t_assert_eq 3 "$(grep -c -e 'download 1018 ' "${fake}/calls")"
  t_assert_grep "${work}/rc" '^0$'
  t_case "the record left out is named in a warning, and the count line says what was read"
  t_assert_grep "${work}/err" '^::warning title=Benchmark history incomplete::left out after 3 tries: gh run download 1018 -n bench-history-k: HTTP 503'
  t_assert_eq 1 "$(grep -c -e '::warning' "${work}/err")" "the download that passed on its second try is no warning"
  t_assert_grep "${work}/out" '^bench-history: read 3 earlier result\(s\) of bench-history-k on develop, 1 left out$'

  t_case "the pause comes between the tries only, and --retry-pause sets it"
  t_assert_eq "[7.5, 7.5] 3" "$(python3 - "${tool}" <<'PY'
import importlib.util
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
import quality_report_github as github

spec = importlib.util.spec_from_file_location("bench_history", sys.argv[1])
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
slept, calls = [], []
time.sleep = slept.append
def refuse(*args):
    calls.append(args)
    raise github.Broken("HTTP 503")
github.download = refuse
failure = bench._try_download("o/r", 1, "bench-history-k", "unused", bench.parse_args(
    ["fetch", "--key", "k", "--dest", "d", "--retry-pause", "7.5"]).retry_pause)
print(slept, len(calls) if failure == "HTTP 503" else failure)
PY
)"
  rm -f "${fake}/fail/"*
}

_section_action() {
  bench_action="${actions}/bench-history/action.yml"
  frontend_action="${actions}/frontend-perf-report/action.yml"
  t_case "the action stores each result as bench-history-<key> for 90 days"
  t_assert_grep "${bench_action}" '^        name: bench-history-\$\{\{ inputs\.key \}\}$'
  t_assert_grep "${bench_action}" '^        retention-days: 90$'
  t_case "a failed comparison is stored too, so its verdict keeps it out of the median"
  t_assert_grep "${bench_action}" "^      if: always\(\) && steps\.report\.outcome != 'skipped'$"
  t_case "the frontend action keeps its inputs and delegates to bench-history"
  t_assert_eq "key timings keep" "$(awk '/^inputs:/ {on = 1; next} /^runs:/ {on = 0} on && /^  [a-z-]+:$/ {sub(/:$/, ""); printf "%s%s", sep, $1; sep = " "}' "${frontend_action}")"
  t_assert_grep "${frontend_action}" '^      uses: Kataglyphis/ANTfrastructure/\.github/actions/bench-history@develop$'
  t_assert_grep "${frontend_action}" '^        format: flutter-frame$'
}

t_sections _section_criterion _section_formats _section_inputs _section_fetch _section_fetch_failures _section_action -- "$@"
t_summary
