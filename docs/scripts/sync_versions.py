#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


START_MARKER = "<!-- generated:version-snapshot:start -->"
END_MARKER = "<!-- generated:version-snapshot:end -->"

REPO_ROOT = Path(__file__).resolve().parents[2]

# ---------------------------------------------------------------------------
# Inline version marker system
#
# In doc files, wrap a version number with paired markers:
#   <!-- generated:cuda -->13.3<!-- /generated:cuda -->
#
# The script replaces the content between markers with the canonical value
# from versions.env, so version references never go stale.
# ---------------------------------------------------------------------------

# marker_name -> (versions.env key, transform)
# transform: 'raw', 'no_v' (strip leading v), 'major', 'major_minor'
INLINE_MARKER_MAP: dict[str, tuple[str, str]] = {
    "cuda": ("CUDA_VERSION", "major_minor"),
    "cuda_full": ("CUDA_VERSION", "raw"),
    "gstreamer": ("GSTREAMER_VERSION", "no_v"),
    "gstreamer_full": ("GSTREAMER_VERSION", "raw"),
    "llvm": ("LLVM_RELEASE", "raw"),
    "gcc": ("GCC_VERSION", "raw"),
    "gcc_major": ("GCC_VERSION", "major"),
    "cmake": ("CMAKE_VERSION", "raw"),
    "vulkan": ("VULKAN_VERSION", "raw"),
    "python": ("PYTHON_VERSION", "raw"),
    "onnx": ("ONNXRUNTIME_VERSION", "no_v"),
    "onnx_full": ("ONNXRUNTIME_VERSION", "raw"),
    "litert": ("LITERT_VERSION", "no_v"),
    "opencv": ("OPENCV_VERSION", "raw"),
    "node": ("NODE_VERSION", "raw"),
    "uv": ("UV_VERSION", "raw"),
    "android_sdk": ("ANDROID_SDK_VERSION", "raw"),
    "android_ndk": ("ANDROID_NDK_VERSION", "raw"),
    "android_cmake": ("ANDROID_CMAKE_VERSION", "raw"),
    "android_build_tools": ("ANDROID_BUILD_TOOLS", "raw"),
    "android_compile_sdk": ("ANDROID_COMPILE_SDK", "raw"),
    "android_api_level": ("ANDROID_API_LEVEL", "raw"),
    "cudnn": ("CUDNN_VERSION", "raw"),
    "tensorrt": ("TENSORRT_VERSION", "raw"),
    "tvm": ("TVM_REF", "raw"),
    "ubuntu": ("UBUNTU_VERSION", "raw"),
    "onnx_genai": ("ONNXRUNTIME_GENAI_VERSION", "no_v"),
}

INLINE_MARKER_RE = re.compile(
    r"<!-- generated:(\w+) -->(.*?)<!-- /generated:\1 -->", re.DOTALL
)


def transform_value(value: str, transform: str) -> str:
    if transform == "raw":
        return value
    if transform == "no_v":
        return value.lstrip("v")
    if transform == "major":
        return value.split(".")[0]
    if transform == "major_minor":
        parts = value.split(".")
        return ".".join(parts[:2]) if len(parts) >= 2 else value
    return value


def resolve_inline_marker_value(
    versions: dict[str, str], marker_name: str
) -> str | None:
    if marker_name not in INLINE_MARKER_MAP:
        return None
    env_var, transform = INLINE_MARKER_MAP[marker_name]
    raw = versions.get(env_var)
    if raw is None:
        return None
    return transform_value(raw, transform)


def inline_marker_replacement(match: re.Match, versions: dict[str, str]) -> str:
    name = match.group(1)
    resolved = resolve_inline_marker_value(versions, name)
    if resolved is None:
        return match.group(0)
    return f"<!-- generated:{name} -->{resolved}<!-- /generated:{name} -->"


# ---------------------------------------------------------------------------


def read_repo_file(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def extract(pattern: str, text: str, description: str) -> str:
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        raise ValueError(f"Could not find {description}")
    return match.group(1)


def parse_versions_env() -> dict[str, str]:
    versions_path = REPO_ROOT / "linux/scripts/01-core/versions.env"
    if not versions_path.exists():
        raise ValueError(f"Canonical versions file not found: {versions_path}")
    result: dict[str, str] = {}
    for line in versions_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip()
        if not key or not value:
            continue
        result[key] = value
    return result


def collect_versions() -> dict[str, str]:
    v = parse_versions_env()

    linux_webserver = read_repo_file("linux/webserver/Dockerfile")
    windows_base = read_repo_file("windows/Dockerfile.base")
    windows_nvidia = read_repo_file("windows/Dockerfile.nvidia")
    windows_media = read_repo_file("windows/Dockerfile.media-merge-builder")
    windows_vs = read_repo_file("windows/scripts/setup-vs.ps1")

    return {
        "linux_ubuntu": v["UBUNTU_VERSION"],
        "linux_cmake": v["CMAKE_VERSION"],
        "linux_vulkan": v["VULKAN_VERSION"],
        "linux_llvm": extract(
            r"(\d+\.\d+\.\d+)",
            v.get("LLVM_RELEASE", "0.0.0"),
            "Linux LLVM version",
        ),
        "linux_gcc": extract(
            r"(\d+)",
            v.get("GCC_VERSION", "0"),
            "Linux GCC major version",
        ),
        "android_sdk": v["ANDROID_SDK_VERSION"],
        "android_ndk": v["ANDROID_NDK_VERSION"],
        "android_cmake": v["ANDROID_CMAKE_VERSION"],
        "webserver_ubuntu": v["UBUNTU_VERSION"],
        "windows_ltsc": extract(
            r"^ARG WINDOWS_LTSC=([^\s]+)$",
            windows_base,
            "Windows LTSC version",
        ),
        "windows_vulkan": extract(r"^ARG VULKAN_VERSION=([^\s]+)$", windows_base, "Windows Vulkan version"),
        "windows_gstreamer": extract(r"^ARG GSTREAMER_VERSION=([^\s]+)$", windows_media, "Windows GStreamer version"),
        "windows_cuda": extract(r"^ARG CUDA_VERSION=([^\s]+)$", windows_nvidia, "Windows CUDA version"),
        # ONNX builds in the media-core branch; Dockerfile.media-merge-builder re-declares the
        # ARG for the merged image's version env vars — both are checked against versions.env.
        "windows_onnx": extract(r"^ARG ONNXRUNTIME_VERSION=([^\s]+)$", windows_media, "Windows ONNX Runtime version"),
        # setup-vs.ps1 no longer hardcodes a `Visual Studio\<major>\BuildTools`
        # path (refactored 2026-07-12, 63d405c). The VS major now lives only in
        # the `$vsMajor = ... else { '<major>' }` fallback, which must stay in
        # sync with versions.env's VISUAL_STUDIO_VERSION.
        "windows_vs": extract(
            # setup-vs.ps1 hoisted the assignment to $script:VsMajor (2026-08-03);
            # accept both the old local and the new script-scoped spelling.
            r"\$(?:script:)?[Vv]sMajor\s*=.*'([0-9]+)'",
            windows_vs,
            "Visual Studio Build Tools major version",
        ),
    }


def render_snapshot() -> str:
    versions = collect_versions()
    return "\n".join(
        [
            START_MARKER,
            "## Source-Controlled Version Snapshot",
            "",
            "This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.",
            "",
            "| Target | Source-controlled defaults |",
            "| --- | --- |",
            (
                "| Linux base image | "
                f"Ubuntu {versions['linux_ubuntu']}, LLVM/Clang {versions['linux_llvm']}, "
                f"GCC {versions['linux_gcc']}, CMake {versions['linux_cmake']}, "
                f"Vulkan SDK {versions['linux_vulkan']} |"
            ),
            (
                "| Android layer | "
                f"Android SDK {versions['android_sdk']}, NDK {versions['android_ndk']}, "
                f"CMake {versions['android_cmake']} |"
            ),
            f"| Webserver image | Ubuntu {versions['webserver_ubuntu']} |",
            (
                "| Windows build image | "
                f"Windows Server Core LTSC {versions['windows_ltsc']}, "
                f"Visual Studio Build Tools {versions['windows_vs']}, "
                f"Vulkan SDK {versions['windows_vulkan']}, "
                f"GStreamer {versions['windows_gstreamer']}, "
                f"CUDA {versions['windows_cuda']}, "
                f"ONNX Runtime {versions['windows_onnx']} |"
            ),
            END_MARKER,
        ]
    )


# -- Snapshot block helpers -------------------------------------------------


def update_marked_block(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    if not pattern.search(original):
        raise ValueError(f"Markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def is_marked_block_current(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    if not pattern.search(original):
        raise ValueError(f"Markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    return updated == original


# -- Inline marker helpers --------------------------------------------------


def inline_marker_target_files() -> list[Path]:
    return sorted(
        path
        for path in (REPO_ROOT / "docs").rglob("*.md")
        if "_build" not in path.parts and ".venv" not in path.parts
    ) + [REPO_ROOT / "README.md", REPO_ROOT / "AGENTS.md"]


def resolve_all_inline_markers(text: str, versions: dict[str, str]) -> str:
    def _replacer(match: re.Match) -> str:
        return inline_marker_replacement(match, versions)
    return INLINE_MARKER_RE.sub(_replacer, text)


def update_inline_markers(file_path: Path, versions: dict[str, str]) -> bool:
    original = file_path.read_text(encoding="utf-8")
    updated = resolve_all_inline_markers(original, versions)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def inline_markers_are_current(file_path: Path, versions: dict[str, str]) -> bool:
    original = file_path.read_text(encoding="utf-8")
    updated = resolve_all_inline_markers(original, versions)
    return updated == original


def check_inline_markers(versions: dict[str, str]) -> int:
    stale = []
    for path in inline_marker_target_files():
        if not inline_markers_are_current(path, versions):
            stale.append(str(path.relative_to(REPO_ROOT)))
    if stale:
        print("Inline version markers are stale in:", file=sys.stderr)
        for p in stale:
            print(f"- {p}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    print("Inline version markers are up to date.")
    return 0


def write_inline_markers(versions: dict[str, str]) -> int:
    changed = []
    for path in inline_marker_target_files():
        if update_inline_markers(path, versions):
            changed.append(str(path.relative_to(REPO_ROOT)))
    if changed:
        print("Updated inline version markers in:")
        for p in changed:
            print(f"- {p}")
    else:
        print("Inline version markers already up to date.")
    return 0


# -- Deps table (third-party-licenses.md) -----------------------------------

DEPS_START_MARKER = "<!-- generated:deps-table:start -->"
DEPS_END_MARKER = "<!-- generated:deps-table:end -->"
DEPS_JSON_PATH = REPO_ROOT / "docs/deps/deps.json"
DEPS_TABLE_FILE = REPO_ROOT / "docs/third-party-licenses.md"


def load_deps_metadata() -> dict:
    import json
    return json.loads(DEPS_JSON_PATH.read_text(encoding="utf-8"))


def resolve_dep_version(entry: dict, versions: dict[str, str]) -> str:
    var = entry.get("var")
    if var and var in versions:
        return versions[var]
    fixed = entry.get("version_fixed")
    if fixed:
        return fixed
    return "—"


def render_deps_table(versions: dict[str, str]) -> str:
    metadata = load_deps_metadata()
    lines: list[str] = [DEPS_START_MARKER]

    for section in metadata["sections"]:
        title = section["title"]
        tag = section.get("tag", "")
        heading = f"## {title}"
        if tag:
            heading += f" (`{tag}`)"
        lines.append("")
        lines.append(heading)
        lines.append("")

        for subsection in section["subsections"]:
            subtitle = subsection["title"]
            df = subsection.get("dockerfile", "")
            sub_heading = f"### {subtitle}"
            if df:
                sub_heading += f" (`{df}`)"
            lines.append(sub_heading)
            lines.append("")
            lines.append("| Software | Version | Repository | License |")
            lines.append("| --- | --- | --- | --- |")

            for entry in subsection["entries"]:
                name = entry["name"]
                ver = resolve_dep_version(entry, versions)
                url = entry.get("url", "")
                lic = entry.get("license", "")
                if url:
                    display = url.replace("https://", "").replace("http://", "").rstrip("/")
                    repo = f"[{display}]({url})"
                else:
                    repo = "—"
                lines.append(f"| {name} | {ver} | {repo} | {lic} |")

            lines.append("")

    lines.append(DEPS_END_MARKER)
    return "\n".join(lines)


def _deps_marker_pattern() -> re.Pattern:
    return re.compile(
        re.escape(DEPS_START_MARKER) + r".*?" + re.escape(DEPS_END_MARKER), re.DOTALL
    )


def update_deps_table(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = _deps_marker_pattern()
    if not pattern.search(original):
        raise ValueError(f"Deps table markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def is_deps_table_current(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = _deps_marker_pattern()
    if not pattern.search(original):
        raise ValueError(f"Deps table markers not found in {file_path}")
    updated = pattern.sub(replacement, original, count=1)
    return updated == original


def check_deps_table(versions: dict[str, str]) -> int:
    try:
        replacement = render_deps_table(versions)
    except FileNotFoundError as e:
        print(f"Deps metadata not found: {e}", file=sys.stderr)
        return 1
    try:
        if is_deps_table_current(DEPS_TABLE_FILE, replacement):
            print("Dependency table is up to date.")
            return 0
        print("Dependency table is out of date.", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1


def write_deps_table(versions: dict[str, str]) -> int:
    try:
        replacement = render_deps_table(versions)
    except FileNotFoundError as e:
        print(f"Deps metadata not found: {e}", file=sys.stderr)
        return 1
    try:
        if update_deps_table(DEPS_TABLE_FILE, replacement):
            print(f"Updated dependency table in {DEPS_TABLE_FILE.relative_to(REPO_ROOT)}")
        else:
            print("Dependency table already up to date.")
        return 0
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1


# -- Dockerfile ARG default syncing -----------------------------------------

_ARG_LINE_RE = re.compile(r'^(\s*ARG\s+)([A-Z][A-Z0-9_]*)=(\S+)')


def dockerfile_target_files() -> list[Path]:
    result = []
    for name in ['base', 'toolchain', 'sdk', 'media', 'android', 'package', 'torch', 'nvidia', 'amd']:
        p = REPO_ROOT / f"linux/Dockerfile.{name}"
        if p.exists():
            result.append(p)
    # Standalone service images build without orchestrator --build-arg forwarding,
    # so their ARG defaults (incl. the UBUNTU_DIGEST pin) are load-bearing.
    for rel in ['linux/webserver/Dockerfile', 'linux/llm-stack/Dockerfile']:
        p = REPO_ROOT / rel
        if p.exists():
            result.append(p)
    # Windows Dockerfiles carry the same versions.env-named ARG defaults (build.ps1
    # overrides them with --build-arg, but the defaults must not drift). ARGs whose
    # names are not versions.env keys (BASE_IMAGE, ...) are untouched by
    # name-matching; derived/renamed ones (OPENCV_SOURCE_VERSION,
    # CUDA_VERSION_MAJOR_MINOR) are covered via _ARG_NAME_ALIASES below.
    result.extend(sorted(REPO_ROOT.glob("windows/Dockerfile*")))
    # The documentation image lives in a submodule and is built on its own rather
    # than by the cross chain, so its PANDOC_*/UV_VERSION pins are `# noforward`.
    # Its ARG defaults are still the real values that image is built from, so they
    # are synced here like any other. Guarded: the submodule may not be checked out.
    doc_image = REPO_ROOT / "external/Kataglyphis-DocumANTation/Dockerfile"
    if doc_image.exists():
        result.append(doc_image)
    return result


# ARG names that carry a versions.env value under a different name (optionally
# transformed — same transform vocabulary as the inline markers). Without an
# alias entry, name-matching skips them and their defaults can drift silently
# (windows CUDA_VERSION_MAJOR_MINOR's default sat stale at the pre-bump value
# because a CUDA_VERSION bump never touched it).
_ARG_NAME_ALIASES: dict[str, tuple[str, str]] = {
    "OPENCV_SOURCE_VERSION": ("OPENCV_VERSION", "raw"),
}
# Windows-only aliases: linux/Dockerfile.nvidia DERIVES the same ARG names via
# shell parameter expansion (13.3.0 → 13.3 → apt form 13-3) — a literal there
# would clobber the deliberate `${CUDA_VERSION_DOT/./-}` default. Windows
# Dockerfiles have no substitution defaults, so theirs must be literal+synced.
_ARG_NAME_ALIASES_WINDOWS: dict[str, tuple[str, str]] = {
    "CUDA_VERSION_MAJOR_MINOR": ("CUDA_VERSION", "major_minor"),
}


def _update_dockerfile_args_inner(file_path: Path, versions: dict[str, str], dry_run: bool) -> bool:
    """Return True if file needs updating (or was updated when not dry_run)."""
    aliases = dict(_ARG_NAME_ALIASES)
    # REPO-RELATIVE check: file_path is absolute, so `"windows" in .parts` would
    # also match a CHECKOUT PATH containing a 'windows' directory and leak the
    # windows-only aliases onto linux Dockerfiles (clobbering their deliberate
    # shell-substitution defaults). All targets live under REPO_ROOT.
    if file_path.relative_to(REPO_ROOT).parts[0] == "windows":
        aliases.update(_ARG_NAME_ALIASES_WINDOWS)
    versions = {**versions, **{
        alias: transform_value(versions[key], tf)
        for alias, (key, tf) in aliases.items()
        if key in versions
    }}
    version_vars = set(versions.keys())
    # newline='' preserves each line's own terminator through the round-trip: the repo
    # freezes per-file line endings (-text; windows Dockerfiles are CRLF, linux LF), so
    # universal-newline translation here would rewrite whole files to the host's EOL.
    with open(file_path, encoding="utf-8", newline="") as fh:
        original = fh.read()
    lines = original.splitlines(keepends=True)
    changed = False
    for i, line in enumerate(lines):
        m = _ARG_LINE_RE.match(line)
        if not m:
            continue
        var_name = m.group(2)
        if var_name not in version_vars:
            continue
        env_val = versions[var_name]
        # versions.env values may carry surrounding quotes (e.g. CUDA_ARCHITECTURES);
        # strip them so the quote style below comes from the ARG line alone --
        # otherwise a quoted env value re-quotes on every run (never idempotent).
        if len(env_val) >= 2 and env_val[0] == env_val[-1] and env_val[0] in "\"'":
            env_val = env_val[1:-1]
        old_raw = m.group(3)
        if old_raw.startswith('"') and old_raw.endswith('"'):
            formatted = f'"{env_val}"'
        elif old_raw.startswith("'") and old_raw.endswith("'"):
            formatted = f"'{env_val}'"
        else:
            formatted = env_val
        if old_raw == formatted:
            continue
        if not dry_run:
            eol = "\r\n" if line.endswith("\r\n") else ("\n" if line.endswith("\n") else "")
            lines[i] = f"{m.group(1)}{var_name}={formatted}{eol}"
        changed = True
    if not dry_run and changed:
        with open(file_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(''.join(lines))
    return changed


def check_dockerfile_args(versions: dict[str, str]) -> int:
    stale = []
    for path in dockerfile_target_files():
        if _update_dockerfile_args_inner(path, versions, dry_run=True):
            stale.append(str(path.relative_to(REPO_ROOT)))
    if stale:
        print("Dockerfile ARG defaults are stale:", file=sys.stderr)
        for p in stale:
            print(f"- {p}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    print("Dockerfile ARG defaults match versions.env.")
    return 0


def write_dockerfile_args(versions: dict[str, str]) -> int:
    changed = []
    for path in dockerfile_target_files():
        if _update_dockerfile_args_inner(path, versions, dry_run=False):
            changed.append(str(path.relative_to(REPO_ROOT)))
    if changed:
        print("Synced Dockerfile ARG defaults in:")
        for p in changed:
            print(f"- {p}")
    else:
        print("Dockerfile ARG defaults already match versions.env.")
    return 0


# -- Windows build-script -DefaultValue syncing ------------------------------
# The build-*-from-source.ps1 scripts carry a hardcoded fallback version in
# Get-SourceBuildVersion's -DefaultValue (a third copy of the pin, after
# versions.env and the Dockerfile ARG default). Normally the container env
# provides the value and the fallback is dead — which is exactly why it drifts
# silently. Keep it honest the same way as the ARG defaults.

_SCRIPT_DEFAULT_RE = re.compile(r"-DefaultValue '([^']*)'")
_SCRIPT_ENVVARS_RE = re.compile(r"-EnvironmentVariables @\(([^)]*)\)")


def script_default_target_files() -> list[Path]:
    return sorted(REPO_ROOT.glob("windows/scripts/build-*-from-source.ps1"))


def _update_script_defaults_inner(file_path: Path, versions: dict[str, str], dry_run: bool) -> bool:
    """Return True if file needs updating (or was updated when not dry_run)."""
    # newline='' round-trips each line's own terminator (frozen per-file EOLs).
    with open(file_path, encoding="utf-8", newline="") as fh:
        original = fh.read()
    lines = original.splitlines(keepends=True)
    changed = False
    for i, line in enumerate(lines):
        if "Get-SourceBuildVersion" not in line:
            continue
        m_def = _SCRIPT_DEFAULT_RE.search(line)
        m_env = _SCRIPT_ENVVARS_RE.search(line)
        if not m_def or not m_env:
            continue
        env_names = re.findall(r"'([^']+)'", m_env.group(1))
        # The first listed env var that versions.env defines is the canonical pin
        # (e.g. OpenCV lists OPENCV_SOURCE_VERSION first but versions.env's key is
        # OPENCV_VERSION).
        key = next((n for n in env_names if n in versions), None)
        if key is None:
            continue
        expected = versions[key]
        if len(expected) >= 2 and expected[0] == expected[-1] and expected[0] in "\"'":
            expected = expected[1:-1]
        # Mirror Get-SourceBuildVersion's -StripVPrefix (-replace '^v', '').
        if "-StripVPrefix" in line and expected.startswith("v"):
            expected = expected[1:]
        if m_def.group(1) == expected:
            continue
        if not dry_run:
            lines[i] = line[: m_def.start(1)] + expected + line[m_def.end(1):]
        changed = True
    if not dry_run and changed:
        with open(file_path, "w", encoding="utf-8", newline="") as fh:
            fh.write("".join(lines))
    return changed


def check_script_defaults(versions: dict[str, str]) -> int:
    stale = []
    for path in script_default_target_files():
        if _update_script_defaults_inner(path, versions, dry_run=True):
            stale.append(str(path.relative_to(REPO_ROOT)))
    if stale:
        print("Windows build-script -DefaultValue pins are stale:", file=sys.stderr)
        for p in stale:
            print(f"- {p}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    print("Windows build-script -DefaultValue pins match versions.env.")
    return 0


def write_script_defaults(versions: dict[str, str]) -> int:
    changed = []
    for path in script_default_target_files():
        if _update_script_defaults_inner(path, versions, dry_run=False):
            changed.append(str(path.relative_to(REPO_ROOT)))
    if changed:
        print("Synced Windows build-script -DefaultValue pins in:")
        for p in changed:
            print(f"- {p}")
    else:
        print("Windows build-script -DefaultValue pins already match versions.env.")
    return 0


# -- Combined flow ----------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sync generated documentation version snapshots.")
    parser.add_argument("--check", action="store_true", help="Fail if generated sections are out of date.")
    parser.add_argument("--write", action="store_true", help="Rewrite generated sections in place.")
    return parser.parse_args()


def target_files() -> list[Path]:
    return [REPO_ROOT / "README.md"]


def check_snapshot(replacement: str) -> int:
    stale_files = [
        str(path.relative_to(REPO_ROOT))
        for path in target_files()
        if not is_marked_block_current(path, replacement)
    ]
    if stale_files:
        print("Generated version snapshot is out of date in:", file=sys.stderr)
        for path in stale_files:
            print(f"- {path}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
        return 1
    print("Generated version snapshot is up to date.")
    return 0


def write_snapshot(replacement: str) -> int:
    changed_files = [
        str(path.relative_to(REPO_ROOT))
        for path in target_files()
        if update_marked_block(path, replacement)
    ]
    if changed_files:
        print("Updated generated version snapshot in:")
        for path in changed_files:
            print(f"- {path}")
    else:
        print("Generated version snapshot already up to date.")
    return 0


def determine_mode(args: argparse.Namespace) -> str:
    if args.check and args.write:
        raise ValueError("Use either --check or --write, not both.")
    return "check" if args.check or not args.write else "write"


def main() -> int:
    args = parse_args()
    try:
        mode = determine_mode(args)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    versions = parse_versions_env()

    if mode == "check":
        result = check_snapshot(render_snapshot())
        result |= check_inline_markers(versions)
        result |= check_deps_table(versions)
        result |= check_dockerfile_args(versions)
        result |= check_script_defaults(versions)
        # Also check website license files.
        import subprocess
        lic_script = REPO_ROOT / "docs/scripts/generate-website-licenses.py"
        lic_result = subprocess.run([sys.executable, str(lic_script), "--check"], capture_output=True, text=True)
        result |= lic_result.returncode
        if lic_result.returncode:
            print(lic_result.stderr, file=sys.stderr)
        return result

    # Sync Dockerfile ARG defaults BEFORE rendering the snapshot: the snapshot
    # extracts versions from the Dockerfiles, so writing it first would leave a
    # freshly-bumped versions.env needing a second --write pass.
    result = write_dockerfile_args(versions)
    result |= write_script_defaults(versions)
    result |= write_snapshot(render_snapshot())
    result |= write_inline_markers(versions)
    result |= write_deps_table(versions)
    # Auto-regenerate website license files so they never go stale.
    import subprocess
    lic_script = REPO_ROOT / "docs/scripts/generate-website-licenses.py"
    lic_result = subprocess.run([sys.executable, str(lic_script), "--write"], capture_output=True, text=True)
    if lic_result.returncode:
        print("WARNING: generate-website-licenses.py --write failed:", file=sys.stderr)
        print(lic_result.stderr, file=sys.stderr)
    else:
        for line in lic_result.stdout.strip().splitlines():
            print(line)
        result |= lic_result.returncode
    return result


if __name__ == "__main__":
    raise SystemExit(main())
