#!/usr/bin/env bash
# Sourced (no shell options); keep in step with WindowsSlang.Common.psm1. Contract: docs/slang-shader-compilation.md
[ -n "${_SLANG_COMPILE_SH_LOADED:-}" ] && return 0
_SLANG_COMPILE_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# Prints like err but returns, so slang_compile_main can hand its wrapper a specific code.
_slang_compile_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# Fills in the derived path defaults. Idempotent.
_slang_compile_apply_defaults() {
  local source_root="${SLANG_COMPILE_SOURCE_ROOT:-}"
  SLANG_COMPILE_SPIRV_OUTPUT_ROOT="${SLANG_COMPILE_SPIRV_OUTPUT_ROOT:-${source_root}/build/spirv}"
  SLANG_COMPILE_WGSL_OUTPUT_ROOT="${SLANG_COMPILE_WGSL_OUTPUT_ROOT:-${source_root}/build/wgsl}"
  SLANG_COMPILE_COMBINED_OUTPUT_DIR="${SLANG_COMPILE_COMBINED_OUTPUT_DIR:-${source_root}/build}"
  SLANG_COMPILE_DEST_ROOT="${SLANG_COMPILE_DEST_ROOT:-$(pwd)}"
}

# Unknown targets are emitted as WGSL, matching the extension rule in slang_compile_targets.
_slang_compile_output_root() {
  if [[ "$1" == "spirv" ]]; then
    printf '%s\n' "${SLANG_COMPILE_SPIRV_OUTPUT_ROOT}"
  else
    printf '%s\n' "${SLANG_COMPILE_WGSL_OUTPUT_ROOT}"
  fi
}

# Manifest reader: python3, not jq (absent from the image); the one place that touches the schema.
slang_compile_manifest_query() {
  python3 - "${SLANG_COMPILE_MANIFEST}" "$@" <<'PY'
import json, sys

manifest_path, query = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
with open(manifest_path, encoding="utf-8") as handle:
    doc = json.load(handle)

if query == "rows":
    for row in doc["manifest"]:
        if row.get("disabled") is True:
            continue
        print("|".join([row["file"], row["entry"], row["stage"], ",".join(row["targets"])]))
elif query == "patch_count":
    print(len(doc.get("depthTexturePatches", {}).get(args[0], [])))
elif query == "patch_field":
    print(doc["depthTexturePatches"][args[0]][int(args[1])][args[2]])
elif query == "wgsl_map":
    for row in doc["wgslMap"]:
        print("|".join([row["src"], row["out"], row["dst"]]))
elif query == "min_slangc_version":
    print(doc.get("minSlangcVersionForWgsl", ""))
else:
    sys.exit(f"unknown manifest query: {query}")
PY
}

# Combined-WGSL emit guard, twinned in PowerShell. See docs/slang-shader-compilation.md#the-combined-emit-outcomes

# <file>; every member of an IO struct needs @builtin or @location. Prints offenders, non-zero if any.
slang_compile_wgsl_varyings_are_located() {
  python3 - "$1" <<'PY'
import re, sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
member = re.compile(r"^\s*((?:@\w+\([^)]*\)\s*)*)([A-Za-z_]\w*)\s*:\s*\S.*?,?\s*$")
offenders = []
index = 0
while index < len(lines):
    head = re.match(r"^struct\s+([A-Za-z_]\w*)", lines[index])
    index += 1
    if head is None:
        continue
    if index < len(lines) and lines[index].strip() == "{":
        index += 1
    members = []
    while index < len(lines) and not lines[index].lstrip().startswith("}"):
        hit = member.match(lines[index])
        if hit is not None:
            members.append((index + 1, hit.group(1), lines[index]))
        index += 1
    io = [m for m in members if "@builtin(" in m[1] or "@location(" in m[1]]
    if not io:
        continue
    for line_no, attrs, raw in members:
        if "@builtin(" not in attrs and "@location(" not in attrs:
            offenders.append(f"{line_no}: struct {head.group(1)}: {raw.strip()}")

for offender in offenders:
    print(offender)
sys.exit(1 if offenders else 0)
PY
}

# MAJOR.MINOR only; an unparseable version counts as new enough, with the emit guard as backstop.
slang_compile_version_at_least() {
  local have="$1" want="$2"
  local have_major have_minor want_major want_minor
  if [[ ! "$have" =~ ^([0-9]+)\.([0-9]+) ]]; then return 0; fi
  have_major="${BASH_REMATCH[1]}"; have_minor="${BASH_REMATCH[2]}"
  if [[ ! "$want" =~ ^([0-9]+)\.([0-9]+) ]]; then return 0; fi
  want_major="${BASH_REMATCH[1]}"; want_minor="${BASH_REMATCH[2]}"
  if ((have_major != want_major)); then ((have_major > want_major)); return; fi
  ((have_minor >= want_minor))
}

# $VULKAN_SDK/bin/slangc, then PATH; returns 1 when neither exists, which the caller maps to exit 2.
slang_compile_resolve_slangc() {
  if [[ -n "${VULKAN_SDK:-}" && -f "${VULKAN_SDK}/bin/slangc" ]]; then
    printf '%s\n' "${VULKAN_SDK}/bin/slangc"
    return 0
  fi
  if command -v slangc &>/dev/null; then
    command -v slangc
    return 0
  fi
  return 1
}

# Conservative: any .slang may be imported, and a manifest edit can retarget any output.
slang_compile_newest_source_stamp() {
  { find "${SLANG_COMPILE_SOURCE_ROOT}" -type f -name '*.slang' -printf '%T@\n'
    find "${SLANG_COMPILE_MANIFEST}" -printf '%T@\n'; } | sort -g | tail -n 1
}

# See docs/cross-build-verification.md#slang-compile-shader-compilation-contract
_slang_compile_collect_subdirs() {
  local -a common_dirs=() other_dirs=()
  local dir rel
  while IFS= read -r -d '' dir; do
    rel="${dir#"${SLANG_COMPILE_SOURCE_ROOT}/"}"
    case "${rel}" in
      build|build/*) continue ;;
    esac
    if [ "${rel}" = "common" ]; then
      common_dirs+=("${dir}")
    else
      other_dirs+=("${dir}")
    fi
  done < <(find "${SLANG_COMPILE_SOURCE_ROOT}" -mindepth 1 -type d -print0 | LC_ALL=C sort -z)
  SLANG_COMPILE_SUBDIRS=(
    ${common_dirs[@]+"${common_dirs[@]}"}
    ${other_dirs[@]+"${other_dirs[@]}"}
  )
}

# slangc resolves `import <name>` on -I paths only, so add every subdirectory.
slang_compile_include_args() {
  local src_parent="$1"
  SLANG_COMPILE_INCLUDE_ARGS=("-I" "${SLANG_COMPILE_SOURCE_ROOT}" "-I" "$src_parent")
  local d
  for d in "${SLANG_COMPILE_SUBDIRS[@]}"; do
    SLANG_COMPILE_INCLUDE_ARGS+=("-I" "$d")
  done
}

# Per-entry-point compilation. Returns 0 to keep set -e in force; a missing source counts as a failure.
slang_compile_targets() {
  local slangc="$1" newest_source="$2"
  local failed_entries=()
  SLANG_COMPILE_COMPILED_COUNT=0

  local file entry_name stage targets
  while IFS='|' read -r file entry_name stage targets; do
    local src_path="${SLANG_COMPILE_SOURCE_ROOT}/${file}"
    if [[ ! -f "$src_path" ]]; then
      warn "Manifest references missing file: $src_path"
      failed_entries+=("$src_path")
      continue
    fi

    slang_compile_include_args "$(dirname "$src_path")"

    local target_list=() target out_ext rel_dir base_name out_dir out_file needs_compile out_stamp
    IFS=',' read -ra target_list <<< "$targets"
    for target in "${target_list[@]}"; do
      if [[ "$target" == "spirv" ]]; then
        out_ext="spv"
      else
        out_ext="wgsl"
      fi
      # Mirror the source subdirectory so same-named entry points do not collide.
      rel_dir="$(dirname "$file")"
      base_name="$(basename "$file" .slang)"
      out_dir="$(_slang_compile_output_root "$target")/${rel_dir}"
      mkdir -p "$out_dir"
      out_file="${out_dir}/${base_name}.${entry_name}.${out_ext}"

      needs_compile=1
      if [[ -f "$out_file" ]]; then
        out_stamp="$(find "$out_file" -printf '%T@')"
        if awk -v o="$out_stamp" -v n="$newest_source" 'BEGIN { exit !(o >= n) }'; then
          needs_compile=0
          info "Up to date: $out_file"
        else
          info "Stale, recompiling: $out_file"
        fi
      fi
      if [[ $needs_compile -eq 0 ]]; then continue; fi

      info "Compiling ${file} (${entry_name} / ${stage}) -> ${target}"
      if ! "$slangc" -target "$target" -stage "$stage" -entry "$entry_name" \
           "${SLANG_COMPILE_INCLUDE_ARGS[@]}" -o "$out_file" "$src_path"; then
        warn "slangc failed: ${file} ${entry_name} -> ${target}"
        failed_entries+=("${src_path} (${entry_name} -> ${target})")
      else
        SLANG_COMPILE_COMPILED_COUNT=$((SLANG_COMPILE_COMPILED_COUNT + 1))
      fi
    done
  done < <(slang_compile_manifest_query rows | tr -d '\r')

  SLANG_COMPILE_FAILED_ENTRIES=("${failed_entries[@]+"${failed_entries[@]}"}")
  return 0
}

# Combined WGSL emit: 0 copied, 1 emit failed, 2 invalid, 3 source absent. docs/slang-shader-compilation.md#the-combined-emit-outcomes
_slang_emit_one_wgsl() {
  local slangc="$1" src_file="$2" out_name="$3" dst_rel="$4" slangc_version="$5"
  local src_path tmp_out dst_dir offenders
  local patch_count i pattern replacement sed_repl before_sum after_sum

  src_path="${SLANG_COMPILE_SOURCE_ROOT}/${src_file}"
  if [[ ! -f "$src_path" ]]; then return 3; fi

  slang_compile_include_args "$(dirname "$src_path")"

  tmp_out="${SLANG_COMPILE_COMBINED_OUTPUT_DIR}/combined_${out_name}"
  # No -entry/-stage: Slang emits ALL entry points in one WGSL file.
  if ! "$slangc" -target wgsl "${SLANG_COMPILE_INCLUDE_ARGS[@]}" -o "$tmp_out" "$src_path"; then
    warn "Combined WGSL emit failed: ${src_file}"
    return 1
  fi

  # Each patch's reason is in the manifest's _comment fields; tr strips a Windows CR.
  patch_count="$(slang_compile_manifest_query patch_count "$out_name" | tr -d '\r')"
  for ((i = 0; i < patch_count; i++)); do
    pattern="$(slang_compile_manifest_query patch_field "$out_name" "$i" pattern | tr -d '\r')"
    replacement="$(slang_compile_manifest_query patch_field "$out_name" "$i" replacement | tr -d '\r')"
    # Rewrite ${N} group references to sed's \N form.
    sed_repl="$(printf '%s' "$replacement" | sed -E 's/\$\{([0-9]+)\}/\\\1/g')"
    before_sum="$(cksum < "$tmp_out")"
    sed -i -E "s|${pattern}|${sed_repl}|g" "$tmp_out"
    after_sum="$(cksum < "$tmp_out")"
    if [[ "$before_sum" == "$after_sum" ]]; then
      warn "${out_name} depth-texture patch '${pattern}' matched nothing - slangc output may have changed"
    fi
  done

  # Validate before overwriting the checked-in file, so a broken emit is never committed.
  if ! offenders="$(slang_compile_wgsl_varyings_are_located "$tmp_out")"; then
    {
      echo "[ERROR] ${out_name}: slangc ${slangc_version} emitted varying struct member(s) with neither"
      echo "[ERROR]   @builtin nor @location - that is not valid WGSL and wgpu/naga will reject it."
      echo "[ERROR]   Emit kept at ${tmp_out}; ${dst_rel}/${out_name} NOT overwritten."
      while IFS= read -r offender; do echo "[ERROR]   ${offender}"; done <<< "$offenders"
    } >&2
    return 2
  fi

  # Copy to the destination shader directory (replaces hand-written WGSL).
  dst_dir="${SLANG_COMPILE_DEST_ROOT}/${dst_rel}"
  mkdir -p "$dst_dir"
  cp "$tmp_out" "${dst_dir}/${out_name}"
}

# Returns 0 like slang_compile_targets; slang_compile_main reports invalid emits last, then exits 1.
slang_compile_combined_wgsl() {
  local slangc="$1"
  local wgsl_failed=() wgsl_invalid=()
  SLANG_COMPILE_WGSL_EMITTED_COUNT=0
  mkdir -p "${SLANG_COMPILE_COMBINED_OUTPUT_DIR}"

  # Below the floor the combined emit drops @location, so skip it; the consumer pins stale WGSL with a test.
  local min_slangc_version slangc_version wgsl_emit_enabled=1
  min_slangc_version="$(slang_compile_manifest_query min_slangc_version | tr -d '\r')"
  slangc_version="$("$slangc" -version 2>&1 | head -n 1 | tr -d '\r')"
  if [[ -n "$min_slangc_version" ]] && ! slang_compile_version_at_least "$slangc_version" "$min_slangc_version"; then
    wgsl_emit_enabled=0
    echo "[WARN] slangc ${slangc_version} is older than ${min_slangc_version}, whose combined (whole-module)" >&2
    echo "[WARN] WGSL emit is the first known-correct one: older builds drop @location(N) from varying" >&2
    echo "[WARN] structs and produce WGSL that wgpu/naga rejects. SKIPPING the combined WGSL emit - the" >&2
    echo "[WARN] checked-in Rust-crate WGSL is left untouched. See docs/slang-shader-compilation.md." >&2
  fi

  local src_file out_name dst_rel rc
  while [[ $wgsl_emit_enabled -eq 1 ]] && IFS='|' read -r src_file out_name dst_rel; do
    rc=0
    _slang_emit_one_wgsl "$slangc" "$src_file" "$out_name" "$dst_rel" "$slangc_version" || rc=$?
    case "$rc" in
      0) SLANG_COMPILE_WGSL_EMITTED_COUNT=$((SLANG_COMPILE_WGSL_EMITTED_COUNT + 1)) ;;
      1) wgsl_failed+=("$src_file") ;;
      2) wgsl_invalid+=("$out_name") ;;
    esac
  done < <(slang_compile_manifest_query wgsl_map | tr -d '\r')

  if [[ ${#wgsl_failed[@]} -gt 0 ]]; then
    echo "[WARN] Combined WGSL emit failed for ${#wgsl_failed[@]} file(s):"
    printf '  %s\n' "${wgsl_failed[@]}"
  fi

  SLANG_COMPILE_INVALID_EMITS=("${wgsl_invalid[@]+"${wgsl_invalid[@]}"}")
  SLANG_COMPILE_MIN_VERSION="${min_slangc_version}"
  SLANG_COMPILE_SLANGC_VERSION="${slangc_version}"
  return 0
}

# Full pipeline
slang_compile_main() {
  _slang_compile_apply_defaults

  if [[ -z "${SLANG_COMPILE_SOURCE_ROOT:-}" || -z "${SLANG_COMPILE_MANIFEST:-}" ]]; then
    _slang_compile_error "slang-compile.sh requires SLANG_COMPILE_SOURCE_ROOT and SLANG_COMPILE_MANIFEST"
    return 2
  fi

  if ! command -v python3 &>/dev/null; then
    _slang_compile_error "python3 not found on PATH - required to read $(basename "${SLANG_COMPILE_MANIFEST}")"
    return 2
  fi

  if [[ ! -d "${SLANG_COMPILE_SOURCE_ROOT}" ]]; then
    echo "[WARN] Slang shader directory not found: ${SLANG_COMPILE_SOURCE_ROOT} - skipping"
    return 0
  fi

  if [[ ! -f "${SLANG_COMPILE_MANIFEST}" ]]; then
    _slang_compile_error "Shader manifest not found: ${SLANG_COMPILE_MANIFEST}"
    return 2
  fi

  local slangc
  if ! slangc="$(slang_compile_resolve_slangc)"; then
    _slang_compile_error "slangc not found in VULKAN_SDK or PATH. Install the Vulkan SDK (ships slangc) or add slangc to PATH."
    return 2
  fi
  info "Using slangc: ${slangc}"

  local newest_source
  newest_source="$(slang_compile_newest_source_stamp)"
  _slang_compile_collect_subdirs

  slang_compile_targets "$slangc" "$newest_source"
  if [[ ${#SLANG_COMPILE_FAILED_ENTRIES[@]} -gt 0 ]]; then
    {
      echo "[ERROR] Slang compilation failed for ${#SLANG_COMPILE_FAILED_ENTRIES[@]} entry point(s):"
      printf '  %s\n' "${SLANG_COMPILE_FAILED_ENTRIES[@]}"
    } >&2
    return 1
  fi

  slang_compile_combined_wgsl "$slangc"

  info "Slang shader compilation finished (${SLANG_COMPILE_COMPILED_COUNT} SPIR-V/WGSL artifact(s) + ${SLANG_COMPILE_WGSL_EMITTED_COUNT} combined WGSL file(s))"

  # Fatal, and last so the SPIR-V summary still prints: an invalid emit is a toolchain regression.
  if [[ ${#SLANG_COMPILE_INVALID_EMITS[@]} -gt 0 ]]; then
    {
      echo "[ERROR] ${#SLANG_COMPILE_INVALID_EMITS[@]} combined WGSL emit(s) had varying struct members without @builtin/@location:"
      printf '  %s\n' "${SLANG_COMPILE_INVALID_EMITS[@]}"
      echo "[ERROR] None of them were copied into the destination shader directories. Fix the toolchain"
      echo "[ERROR] (slangc >= ${SLANG_COMPILE_MIN_VERSION} is known good; this run used ${SLANG_COMPILE_SLANGC_VERSION}) - do not hand-patch the generated WGSL."
    } >&2
    return 1
  fi
  return 0
}
