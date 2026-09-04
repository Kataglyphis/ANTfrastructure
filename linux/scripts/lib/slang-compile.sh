#!/usr/bin/env bash
# slang-compile.sh - generic "compile a Slang shader tree to SPIR-V and WGSL" driver.
#
# Project-agnostic: a wrapper sets SLANG_COMPILE_MANIFEST and
# SLANG_COMPILE_SOURCE_ROOT (plus optional output roots), sources this file and
# calls slang_compile_main. Variables, manifest schema, return codes and the
# staleness rule are in docs/slang-shader-compilation.md.
#
# PowerShell twin: windows/scripts/modules/WindowsSlang.Common.psm1 -- keep in step.
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.
[ -n "${_SLANG_COMPILE_SH_LOADED:-}" ] && return 0
_SLANG_COMPILE_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# Fatal-but-not-exiting variant: prints like err, but lets slang_compile_main
# return a specific code to its wrapper instead of exiting the shell itself.
_slang_compile_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# Fills in the derived path defaults. Idempotent.
_slang_compile_apply_defaults() {
  local source_root="${SLANG_COMPILE_SOURCE_ROOT:-}"
  SLANG_COMPILE_SPIRV_OUTPUT_ROOT="${SLANG_COMPILE_SPIRV_OUTPUT_ROOT:-${source_root}/build/spirv}"
  SLANG_COMPILE_WGSL_OUTPUT_ROOT="${SLANG_COMPILE_WGSL_OUTPUT_ROOT:-${source_root}/build/wgsl}"
  SLANG_COMPILE_COMBINED_OUTPUT_DIR="${SLANG_COMPILE_COMBINED_OUTPUT_DIR:-${source_root}/build}"
  SLANG_COMPILE_DEST_ROOT="${SLANG_COMPILE_DEST_ROOT:-$(pwd)}"
}

# The output root for a manifest target. Unknown targets are emitted as WGSL,
# matching the extension rule in slang_compile_targets.
_slang_compile_output_root() {
  if [[ "$1" == "spirv" ]]; then
    printf '%s\n' "${SLANG_COMPILE_SPIRV_OUTPUT_ROOT}"
  else
    printf '%s\n' "${SLANG_COMPILE_WGSL_OUTPUT_ROOT}"
  fi
}

# ---------------------------------------------------------------------------
# Manifest reader
# ---------------------------------------------------------------------------
# The manifest is read with python3, NOT jq: jq is absent from the ContainerHub
# Linux image (verified 2026-08-02 - a jq dependency here made shader
# precompilation fail, and the consumer's `|| warn` hid it, leaving CI with no
# SPIR-V at all), while python3 ships in the image and is already a documented
# project dependency. One reader, no second parser to drift.
#
# slang_compile_manifest_query <query-name> [args...]
# Emits pipe-delimited rows on stdout. Every query lives here so the JSON schema
# is touched in exactly one place.
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

# ---------------------------------------------------------------------------
# Combined-WGSL emit correctness guard.
#
# WGSL requires every non-builtin member of an inter-stage (varying) struct to
# carry @location(N). slangc 2026.1-52-gc8ddf20bb - the build in Vulkan SDK
# 1.4.341.1, i.e. the ContainerHub Linux image - drops that attribute in the
# COMBINED emit (no -entry/-stage) while emitting it correctly per entry point,
# so a regeneration on that toolchain silently produced WGSL naga rejects.
# 2026.8 is correct on both Windows and Linux. Two defences, both needed:
#   1. the manifest's minSlangcVersionForWgsl floor: below it we do not emit at
#      all, so the (correct) checked-in WGSL is never overwritten.
#   2. slang_compile_wgsl_varyings_are_located: at or above the floor we emit and
#      then verify, so ANY future emit regression fails the build instead of
#      being copied.
# The same rule is reimplemented in the PowerShell twin
# (windows/scripts/modules/WindowsSlang.Common.psm1) - keep the two in step, and
# with whatever test the consuming project pins it with.
# ---------------------------------------------------------------------------

# slang_compile_wgsl_varyings_are_located <file>
# A struct with at least one @builtin/@location member is an IO struct; every
# member of it must then carry one of those attributes. Prints offenders and
# returns non-zero when the file is invalid.
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

# slang_compile_version_at_least <have> <want> - compares the leading
# MAJOR.MINOR only. slangc prints e.g. "2026.8" or "2026.1-52-gc8ddf20bb". An
# unparseable version is treated as new enough: the emit guard above is the
# backstop, and refusing to compile on an unrecognised version string would be
# worse.
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

# Prints the slangc to use: $VULKAN_SDK/bin/slangc, then PATH. Returns 1 when
# neither exists (the caller turns that into the "exit 2" contract).
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

# Newest mtime across every .slang file under the source tree and the manifest
# itself: every .slang file is a potential import dependency, and a manifest
# edit can retarget any output (conservative staleness).
slang_compile_newest_source_stamp() {
  { find "${SLANG_COMPILE_SOURCE_ROOT}" -type f -name '*.slang' -printf '%T@\n'
    find "${SLANG_COMPILE_MANIFEST}" -printf '%T@\n'; } | sort -g | tail -n 1
}

# The slang compile contract and its fallbacks:
# docs/cross-build-verification.md
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

# slangc resolves `import <name>` to <name>.slang on the -I paths. Add the
# source root, the source's own directory and every subdirectory so
# `import aces` finds common/aces.slang regardless of where the importing
# shader lives. Fills SLANG_COMPILE_INCLUDE_ARGS.
slang_compile_include_args() {
  local src_parent="$1"
  SLANG_COMPILE_INCLUDE_ARGS=("-I" "${SLANG_COMPILE_SOURCE_ROOT}" "-I" "$src_parent")
  local d
  for d in "${SLANG_COMPILE_SUBDIRS[@]}"; do
    SLANG_COMPILE_INCLUDE_ARGS+=("-I" "$d")
  done
}

# ---------------------------------------------------------------------------
# Per-entry-point compilation (the manifest[] rows)
# ---------------------------------------------------------------------------
# Compiles every enabled (file, entry, target) row, skipping outputs that are
# already up to date. Sets SLANG_COMPILE_COMPILED_COUNT and
# SLANG_COMPILE_FAILED_ENTRIES - the latter also collects rows naming a source
# file that does not exist, which is a manifest bug and must never pass
# silently. Always returns 0 so that the caller's `set -e` stays in force inside
# this function; slang_compile_main turns a non-empty failure list into exit 1.
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
      # Mirror the source subdirectory under the target's output root so
      # distinct shaders with the same entry-point name do not collide.
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

# ---------------------------------------------------------------------------
# Combined WGSL emit: compile each wgslMap source WITHOUT -entry/-stage to get
# all entry points in one WGSL file, then copy it to the destination directory
# the manifest names (e.g. a Rust crate's shader directory, so include_str!
# picks up the Slang-emitted WGSL).
# ---------------------------------------------------------------------------
# Sets SLANG_COMPILE_WGSL_EMITTED_COUNT and SLANG_COMPILE_INVALID_EMITS (emits
# that violated the WGSL varying rules; none of those are copied). Always
# returns 0 - see slang_compile_targets for why - and slang_compile_main reports
# the invalid emits last, after the summary line, then exits 1.
slang_compile_combined_wgsl() {
  local slangc="$1"
  local wgsl_failed=() wgsl_invalid=()
  SLANG_COMPILE_WGSL_EMITTED_COUNT=0
  mkdir -p "${SLANG_COMPILE_COMBINED_OUTPUT_DIR}"

  # Toolchain floor: below it slangc's combined emit is known to drop varying
  # @location attributes, so skip the emit entirely rather than overwrite the
  # checked-in WGSL with output naga rejects. Regenerating after a .slang edit
  # then needs a newer slangc - the consuming project is expected to pin that
  # with a test (here:
  # BuildIntegrity.CheckedInWgslIsNotOlderThanItsSlangSource) so a skipped and
  # forgotten regeneration fails.
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

  local src_file out_name dst_rel src_path tmp_out
  local patch_count i pattern replacement sed_repl before_sum after_sum offenders dst_dir
  while [[ $wgsl_emit_enabled -eq 1 ]] && IFS='|' read -r src_file out_name dst_rel; do
    src_path="${SLANG_COMPILE_SOURCE_ROOT}/${src_file}"
    if [[ ! -f "$src_path" ]]; then continue; fi

    slang_compile_include_args "$(dirname "$src_path")"

    tmp_out="${SLANG_COMPILE_COMBINED_OUTPUT_DIR}/combined_${out_name}"
    # No -entry/-stage: Slang emits ALL entry points in one WGSL file.
    if ! "$slangc" -target wgsl "${SLANG_COMPILE_INCLUDE_ARGS[@]}" -o "$tmp_out" "$src_path"; then
      warn "Combined WGSL emit failed: ${src_file}"
      wgsl_failed+=("$src_file")
      continue
    fi

    # Post-emit patch table (depthTexturePatches): why each patch exists is
    # documented in the "_comment" fields next to the patterns in the manifest.
    # tr strips the CR a Windows host may add (harmless on Linux).
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

    # Reject a structurally invalid emit BEFORE it can overwrite the checked-in
    # file, so a broken regeneration can never be committed silently.
    if ! offenders="$(slang_compile_wgsl_varyings_are_located "$tmp_out")"; then
      {
        echo "[ERROR] ${out_name}: slangc ${slangc_version} emitted varying struct member(s) with neither"
        echo "[ERROR]   @builtin nor @location - that is not valid WGSL and wgpu/naga will reject it."
        echo "[ERROR]   Emit kept at ${tmp_out}; ${dst_rel}/${out_name} NOT overwritten."
        while IFS= read -r offender; do echo "[ERROR]   ${offender}"; done <<< "$offenders"
      } >&2
      wgsl_invalid+=("${out_name}")
      continue
    fi

    # Copy to the destination shader directory (replaces hand-written WGSL).
    dst_dir="${SLANG_COMPILE_DEST_ROOT}/${dst_rel}"
    mkdir -p "$dst_dir"
    cp "$tmp_out" "${dst_dir}/${out_name}"
    SLANG_COMPILE_WGSL_EMITTED_COUNT=$((SLANG_COMPILE_WGSL_EMITTED_COUNT + 1))
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

# ---------------------------------------------------------------------------
# Full pipeline
# ---------------------------------------------------------------------------
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

  # Fatal, and last so the SPIR-V summary above is still reported: an emit that
  # violates WGSL's varying rules is a toolchain regression, not a warning.
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
