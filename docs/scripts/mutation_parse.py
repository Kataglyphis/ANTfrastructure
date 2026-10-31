"""Refuse a mutation whose target parses and whose mutant does not: its bite proves a syntax error, not the removed guarantee.

Checks bash -n (CR stripped) for *.sh and bash or sh shebang files, compile() for *.py and one pwsh parse for every *.ps1/*.psm1.
Does NOT cover other languages (YAML, JSON, JavaScript, Dockerfiles, CMake), code embedded in another file (heredocs,
workflow run: blocks), names that parse but cannot resolve at run time, or a target that already fails to parse.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import warnings
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from typing import NamedTuple

_SHELL_SHEBANG = re.compile(r"#![ \t]*(?:/usr/bin/env[ \t]+(?:-S[ \t]+)?)?(?:/\S*/)?(?:ba)?sh(?:[ \t]|$)")
_PWSH_PARSE = r"""
$ErrorActionPreference = 'Stop'
$texts = Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json
$answers = foreach ($text in $texts) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput([string]$text, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { 'line {0}: {1}' -f $errors[0].Extent.StartLineNumber, $errors[0].Message } else { '' }
}
ConvertTo-Json -InputObject @($answers) -Compress
"""


class MissingParser(Exception):
    """A parser the selection needs is absent: the check fails rather than skip what it cannot read."""


class Edit(NamedTuple):
    id: str
    target: str
    original: str
    mutated: str


def parser_for(target: str, text: str) -> str | None:
    """'bash', 'python', 'pwsh' or None for a target this check does not read."""
    name = target.rsplit("/", 1)[-1]
    if name.endswith(".sh") or _SHELL_SHEBANG.match(text.split("\n", 1)[0]):
        return "bash"
    if name.endswith(".py"):
        return "python"
    if name.endswith((".ps1", ".psm1")):
        return "pwsh"
    return None


def _bash_error(text: str) -> str | None:
    proc = subprocess.run(["bash", "-n"], input=text.replace("\r", ""), capture_output=True,
                          text=True, check=False)
    if proc.returncode == 0:
        return None
    lines = [line for line in proc.stderr.splitlines() if line.strip()]
    return "bash -n: " + (lines[0].strip() if lines else f"exit {proc.returncode}")


def _python_error(text: str, target: str) -> str | None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            compile(text, target, "exec", dont_inherit=True)
        except SyntaxError as exc:
            return f"compile(): line {exc.lineno}: {exc.msg}"
        except ValueError as exc:
            return f"compile(): {exc}"
    return None


def _pwsh_errors(texts: Sequence[str]) -> list[str | None]:
    """One pwsh process parses every text: a process per mutant would cost a second each."""
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        raise MissingParser("pwsh is not on PATH, so PowerShell mutants cannot be checked to parse")
    with tempfile.TemporaryDirectory(prefix="mutation-parse-") as tmp:
        inputs, script = os.path.join(tmp, "texts.json"), os.path.join(tmp, "parse.ps1")
        with open(inputs, "w", encoding="utf-8") as fh:
            json.dump(list(texts), fh)
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(_PWSH_PARSE)
        proc = subprocess.run([pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, inputs],
                              capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        raise MissingParser(f"pwsh could not parse the PowerShell mutants (exit {proc.returncode}): {proc.stderr.strip()[:300]}")
    answers = json.loads(proc.stdout)
    if not isinstance(answers, list) or len(answers) != len(texts):
        raise MissingParser(f"pwsh answered {proc.stdout.strip()[:200]!r} for {len(texts)} text(s)")
    return [f"PowerShell parser: {a}" if a else None for a in answers]


def _local_errors(kind: str, items: Sequence[tuple[str, str]]) -> list[str | None]:
    if kind == "python":
        return [_python_error(text, target) for target, text in items]
    if shutil.which("bash") is None:
        raise MissingParser("bash is not on PATH, so shell mutants cannot be checked to parse")
    with ThreadPoolExecutor(max_workers=(os.cpu_count() or 1)) as pool:
        return list(pool.map(lambda item: _bash_error(item[1]), items))


def _errors(kind: str, items: Sequence[tuple[str, str]]) -> list[str | None]:
    if kind == "pwsh":
        return _pwsh_errors([text for _target, text in items]) if items else []
    return _local_errors(kind, items)


def refusals(edits: Sequence[Edit]) -> dict[str, str]:
    """id -> reason for each edit whose original parses and whose mutant does not."""
    groups: dict[str, list[Edit]] = {}
    for edit in edits:
        kind = parser_for(edit.target, edit.original)
        if kind is not None:
            groups.setdefault(kind, []).append(edit)
    refused: dict[str, str] = {}
    for kind, group in groups.items():
        originals = sorted({(e.target, e.original) for e in group})
        # One call per parser, originals first: pwsh starts once for every text.
        answers = _errors(kind, originals + [(e.target, e.mutated) for e in group])
        broken = {key for key, err in zip(originals, answers) if err}
        for edit, err in zip(group, answers[len(originals):]):
            if err and (edit.target, edit.original) not in broken:
                refused[edit.id] = err
    return refused
