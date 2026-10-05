#!/usr/bin/env python3
"""Propagate versions.env into every file that repeats its numbers; --check is the version-snapshot slug (docs/cross-build-verification.md#pre-flight)."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from consumer_pins import check_consumer_pins


START_MARKER = "<!-- generated:version-snapshot:start -->"
END_MARKER = "<!-- generated:version-snapshot:end -->"

REPO_ROOT = Path(__file__).resolve().parents[2]

# Inline markers: the value between <!-- generated:cuda --> and <!-- /generated:cuda --> is rewritten from versions.env.

# marker_name -> (versions.env key, transform: raw | no_v | major | major_minor)
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
    # tool-pins.env holds the host-tool pins no image build reads (CON59); the two never share a key.
    for path in (versions_path, versions_path.with_name("tool-pins.env")):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
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
    windows_vs = read_repo_file("windows/scripts/host/Install-Vs.ps1")

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
        # Dockerfile.media-merge-builder re-declares the ONNX ARG for the merged image's env; both are checked.
        "windows_onnx": extract(r"^ARG ONNXRUNTIME_VERSION=([^\s]+)$", windows_media, "Windows ONNX Runtime version"),
        # The VS major lives only in Install-Vs.ps1's $VsMajor fallback, which must match VISUAL_STUDIO_VERSION.
        "windows_vs": extract(
            # Accept both the local and the script-scoped spelling.
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
    # A lambda: a plain string is a re.sub template that would interpret backslashes.
    updated = pattern.sub(lambda _m: replacement, original, count=1)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def is_marked_block_current(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    if not pattern.search(original):
        raise ValueError(f"Markers not found in {file_path}")
    updated = pattern.sub(lambda _m: replacement, original, count=1)
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


# Any opener or closer token naming an inline marker; \w+ names keep the block markers and prose mentions out.
_MARKER_TOKEN_RE = re.compile(r"<!--\s*/?\s*generated:(\w+)\s*-->")


def validate_inline_marker_tokens() -> int:
    """Fail on unknown marker names and on tokens outside a well-formed pair, which the updater would silently skip."""
    problems: list[str] = []
    for path in inline_marker_target_files():
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(REPO_ROOT))
        for m in INLINE_MARKER_RE.finditer(text):
            if m.group(1) not in INLINE_MARKER_MAP:
                problems.append(
                    f"{rel}: unknown inline marker name 'generated:{m.group(1)}'"
                    " (not in INLINE_MARKER_MAP — typo, or add a mapping)"
                )
        # Once every well-formed pair is removed, any surviving token is unpaired or malformed.
        residual = INLINE_MARKER_RE.sub("", text)
        for m in _MARKER_TOKEN_RE.finditer(residual):
            problems.append(
                f"{rel}: marker token '{m.group(0)}' has no well-formed"
                " `<!-- generated:X -->value<!-- /generated:X -->` pair"
            )
    if problems:
        print("Inline marker validation FAILED:", file=sys.stderr)
        for p in problems:
            print(f"- {p}", file=sys.stderr)
        return 1
    print("Inline marker tokens are well-formed and known.")
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


# Deps table (third-party-licenses.md), rendered by deps_table.py, shared with generate-website-licenses.py.

from deps_table import (  # noqa: E402
    render_deps_table_lines,
    render_modified_lines,
    render_obligations_lines,
    render_source_offer_lines,
)

DEPS_START_MARKER = "<!-- generated:deps-table:start -->"
DEPS_END_MARKER = "<!-- generated:deps-table:end -->"
DEPS_TABLE_FILE = REPO_ROOT / "docs/third-party-licenses.md"


def render_deps_table(versions: dict[str, str]) -> str:
    # Same obligation and source sections as the website page: developers need to see the source-offer duty.
    lines = [
        DEPS_START_MARKER,
        *render_deps_table_lines(versions),
        "", "---",
        *render_obligations_lines(),
        "", "---",
        *render_source_offer_lines(versions),
        *render_modified_lines(),
        DEPS_END_MARKER,
    ]
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
    # Lambda replacement: avoid re.sub backslash-template interpretation.
    updated = pattern.sub(lambda _m: replacement, original, count=1)
    if updated == original:
        return False
    file_path.write_text(updated, encoding="utf-8")
    return True


def is_deps_table_current(file_path: Path, replacement: str) -> bool:
    original = file_path.read_text(encoding="utf-8")
    pattern = _deps_marker_pattern()
    if not pattern.search(original):
        raise ValueError(f"Deps table markers not found in {file_path}")
    updated = pattern.sub(lambda _m: replacement, original, count=1)
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
    # Standalone service images get no --build-arg forwarding, so their ARG defaults are load-bearing.
    for rel in ['linux/webserver/Dockerfile', 'linux/llm-stack/Dockerfile']:
        p = REPO_ROOT / rel
        if p.exists():
            result.append(p)
    # Windows defaults are overridden at build time but must not drift; renamed ARGs go through the aliases below.
    result.extend(sorted(REPO_ROOT.glob("windows/Dockerfile*")))
    # The documentation image's pins are noforward but still its real build values; the submodule may be absent.
    doc_image = REPO_ROOT / "third_party/DocumANTation/Dockerfile"
    if doc_image.exists():
        result.append(doc_image)
    return result


# ARGs carrying a versions.env value under another name (inline-marker transforms); unaliased, they drift silently.
_ARG_NAME_ALIASES: dict[str, tuple[str, str]] = {
    "OPENCV_SOURCE_VERSION": ("OPENCV_VERSION", "raw"),
}
# Windows only: linux/Dockerfile.nvidia derives these names by shell expansion, which a literal would clobber.
_ARG_NAME_ALIASES_WINDOWS: dict[str, tuple[str, str]] = {
    "CUDA_VERSION_MAJOR_MINOR": ("CUDA_VERSION", "major_minor"),
}


def _unquote(value: str) -> str:
    """Strip one surrounding quote pair, or a quoted versions.env value is re-quoted on every run."""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _rewrite_lines(file_path: Path, dry_run: bool, rewrite) -> bool:
    """Rewrite lines for which rewrite(line) returns one, keeping each file's frozen EOL (newline=''); True if anything changed."""
    with open(file_path, encoding="utf-8", newline="") as fh:
        lines = fh.read().splitlines(keepends=True)
    changed = False
    for i, line in enumerate(lines):
        new_line = rewrite(line)
        if new_line is None:
            continue
        changed = True
        if not dry_run:
            lines[i] = new_line
    if not dry_run and changed:
        with open(file_path, "w", encoding="utf-8", newline="") as fh:
            fh.write("".join(lines))
    return changed


def _update_dockerfile_args_inner(file_path: Path, versions: dict[str, str], dry_run: bool) -> bool:
    """Return True if file needs updating (or was updated when not dry_run)."""
    aliases = dict(_ARG_NAME_ALIASES)
    # Repo-relative, so a 'windows' directory in the checkout path cannot leak these aliases onto linux files.
    if file_path.relative_to(REPO_ROOT).parts[0] == "windows":
        aliases.update(_ARG_NAME_ALIASES_WINDOWS)
    versions = {**versions, **{
        alias: transform_value(versions[key], tf)
        for alias, (key, tf) in aliases.items()
        if key in versions
    }}
    version_vars = set(versions.keys())

    def rewrite(line: str) -> str | None:
        m = _ARG_LINE_RE.match(line)
        if not m:
            return None
        var_name = m.group(2)
        if var_name not in version_vars:
            return None
        # Never rewrite substitution defaults (ARG X=${Y...}): a literal would clobber the derivation.
        if m.group(3).startswith("${"):
            return None
        env_val = _unquote(versions[var_name])
        old_raw = m.group(3)
        if old_raw.startswith('"') and old_raw.endswith('"'):
            formatted = f'"{env_val}"'
        elif old_raw.startswith("'") and old_raw.endswith("'"):
            formatted = f"'{env_val}'"
        else:
            formatted = env_val
        if old_raw == formatted:
            return None
        # Splice only the value, keeping a trailing comment, whitespace and the line's own EOL.
        return f"{m.group(1)}{var_name}={formatted}{line[m.end(3):]}"

    return _rewrite_lines(file_path, dry_run, rewrite)


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


# Windows build-script -DefaultValue syncing: a fallback the container env normally shadows, so it drifts silently.

_SCRIPT_DEFAULT_RE = re.compile(r"-DefaultValue '([^']*)'")
_SCRIPT_ENVVARS_RE = re.compile(r"-EnvironmentVariables @\(([^)]*)\)")
# A commit override listed first while -DefaultValue is the tag; PinParity carries the same exception, keep them in step.
_SCRIPT_DEFAULT_KEY_OVERRIDES = {"Build-TvmFromSource.ps1|TVM_COMMIT": "TVM_REF"}


def script_default_target_files() -> list[Path]:
    # A glob that matches nothing silently drops every script from the gate.
    return sorted(REPO_ROOT.glob("windows/scripts/**/Build-*FromSource.ps1"))


def _update_script_defaults_inner(file_path: Path, versions: dict[str, str], dry_run: bool) -> bool:
    """Return True if file needs updating (or was updated when not dry_run)."""
    def rewrite(line: str) -> str | None:
        if "Get-SourceBuildVersion" not in line:
            return None
        m_def = _SCRIPT_DEFAULT_RE.search(line)
        m_env = _SCRIPT_ENVVARS_RE.search(line)
        if not m_def or not m_env:
            return None
        env_names = re.findall(r"'([^']+)'", m_env.group(1))
        # The first listed env var that versions.env defines is the canonical pin.
        key = next((n for n in env_names if n in versions), None)
        if key is None:
            return None
        key = _SCRIPT_DEFAULT_KEY_OVERRIDES.get(f"{file_path.name}|{key}", key)
        expected = _unquote(versions[key])
        # Mirror Get-SourceBuildVersion's -StripVPrefix (-replace '^v', '').
        if "-StripVPrefix" in line and expected.startswith("v"):
            expected = expected[1:]
        if m_def.group(1) == expected:
            return None
        return line[: m_def.start(1)] + expected + line[m_def.end(1):]

    return _rewrite_lines(file_path, dry_run, rewrite)


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
    parser.add_argument(
        "--consumer-root",
        action="append",
        default=[],
        metavar="DIR",
        help="A consumer repo checkout whose own copies of versions.env pins "
             "(pyproject.toml, .pre-commit-config.yaml) are compared against this "
             "repo's. Repeatable. Never written to, in any mode.",
    )
    parser.add_argument(
        "--consumer-pins",
        action="store_true",
        help="Run ONLY the consumer pin forwarding check, over the roots named "
             "by --consumer-root (or the vendored position). This is the mode "
             "run-lint-gates.sh calls from a consumer's lane; a run with no "
             "usable root FAILS instead of reporting NOT CHECKED.",
    )
    return parser.parse_args()


def target_files() -> list[Path]:
    return [REPO_ROOT / "README.md"]


# Literals in code spans, where inline markers cannot live; narrative lines are allowlisted by content, not line number.
DOC_LITERAL_FILES = (
    "docs/linux-cross-builds.md",
    "docs/linux-build-basics.md",
    "AGENTS.md",
)
DOC_LITERAL_ALLOWLIST = (
    # the --no-push digest-trail war story (an OLD gcc prefix is the point)
    re.compile(r"inherited from"),
    # the PR100017 / upstream-fix narrative referencing the era it happened
    re.compile(r"war story|historisch|previously|the old ", re.IGNORECASE),
    # A distro-version contrast; line-level, so a pin on the same line is exempted too: name the KEY in docs instead.
    re.compile(r"not Ubuntu"),
)


def check_doc_literals(versions: dict[str, str]) -> int:
    gcc = versions.get("GCC_VERSION", "")
    llvm = versions.get("LLVM_RELEASE", "")
    gcc_rx = re.compile(r"/opt/gcc-(\d+\.\d+\.\d+)")
    # "clang 22.1.8" and "clang --version reports 22.1.8"; the second stays narrow so changelog lines do not fire.
    llvm_rx = re.compile(r"[Cc]lang[- ]?(2\d\.\d+\.\d+)")
    llvm_reports_rx = re.compile(r"[Cc]lang[^`\n]{0,40}--version[^`\n]{0,40}reports?[^0-9\n]{0,20}(2\d\.\d+\.\d+)")
    bad = 0
    for rel in DOC_LITERAL_FILES:
        path = REPO_ROOT / rel
        if not path.exists():
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if any(rx.search(line) for rx in DOC_LITERAL_ALLOWLIST):
                continue
            for m in gcc_rx.finditer(line):
                if gcc and m.group(1) != gcc:
                    print(f"{rel}:{lineno}: stale gcc literal /opt/gcc-{m.group(1)} (pin: {gcc})")
                    bad = 1
            for rx in (llvm_rx, llvm_reports_rx):
                for m in rx.finditer(line):
                    if llvm and m.group(1) != llvm:
                        print(f"{rel}:{lineno}: stale clang literal {m.group(1)} (pin: {llvm})")
                        bad = 1
    if not bad:
        print("Doc version literals match versions.env pins.")
    return bad


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
    if args.consumer_pins and (args.check or args.write):
        raise ValueError(
            "--consumer-pins runs that check ALONE; combine it with neither "
            "--check nor --write (--check already includes it)."
        )
    if args.consumer_pins:
        return "consumer-pins"
    return "check" if args.check or not args.write else "write"


def main() -> int:
    args = parse_args()
    try:
        mode = determine_mode(args)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    versions = parse_versions_env()

    if mode == "consumer-pins":
        # Only this section: the rest grades the vendored hub, not the consumer tree the lane was given.
        return check_consumer_pins(
            versions, args.consumer_root, REPO_ROOT, required=True
        )

    if mode == "check":
        result = check_snapshot(render_snapshot())
        result |= validate_inline_marker_tokens()
        result |= check_inline_markers(versions)
        result |= check_deps_table(versions)
        result |= check_dockerfile_args(versions)
        result |= check_script_defaults(versions)
        result |= check_doc_literals(versions)
        result |= check_consumer_pins(versions, args.consumer_root, REPO_ROOT)
        # Also check website license files.
        import subprocess
        lic_script = REPO_ROOT / "docs/scripts/generate-website-licenses.py"
        lic_result = subprocess.run([sys.executable, str(lic_script), "--check"], capture_output=True, text=True)
        result |= lic_result.returncode
        if lic_result.returncode:
            print(lic_result.stderr, file=sys.stderr)
        return result

    # Dockerfile ARGs first: the snapshot reads its versions back out of the Dockerfiles.
    result = write_dockerfile_args(versions)
    result |= write_script_defaults(versions)
    result |= write_snapshot(render_snapshot())
    # A malformed marker must fail --write too, since the updater silently skips it.
    result |= validate_inline_marker_tokens()
    result |= write_inline_markers(versions)
    result |= write_deps_table(versions)
    # --write cannot repair consumer copies, so check them: a contradicting consumer must not exit 0.
    result |= check_consumer_pins(versions, args.consumer_root, REPO_ROOT)
    # Auto-regenerate website license files so they never go stale.
    import subprocess
    lic_script = REPO_ROOT / "docs/scripts/generate-website-licenses.py"
    lic_result = subprocess.run([sys.executable, str(lic_script), "--write"], capture_output=True, text=True)
    if lic_result.returncode:
        print("ERROR: generate-website-licenses.py --write failed:", file=sys.stderr)
        print(lic_result.stderr, file=sys.stderr)
        # --write must not exit 0 when the license files could not be written.
        result |= 1
    else:
        for line in lic_result.stdout.strip().splitlines():
            print(line)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
