# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Native-invocation helpers. Deliberately NOT in WindowsScripts.Shared.psm1:
# Shared is COPY'd into Dockerfile.base BEFORE the hours-long VS Build Tools
# layer, so any edit there re-pays the VS install across both lanes. This
# module is only picked up by the final stage's whole-dir modules COPY (cheap).
# NOTE for future migrations: the two "no callers in this repo" path helpers in
# Shared (Resolve-WorkspacePath/Resolve-NormalizedPath) are EXTERNAL-consumer
# API (Kataglyphis-Inference-Engine's Build-Windows.ps1) — same caution applies.

Set-StrictMode -Version Latest

function Invoke-ShieldedNative {
    <#
    .SYNOPSIS
        Canonical stderr-shielded native call: `cmd.exe /c "<line> 2>&1"` +
        throw on non-zero exit (unless -Optional).
    .DESCRIPTION
        Native tools (git, make, bash) write progress to stderr, which the
        in-container PS 5.1 under $ErrorActionPreference='Stop' turns into a
        terminating NativeCommandError even with `2>&1` (5.1 merges the stream
        too late). Routing through cmd.exe merges the streams before PowerShell
        sees them. Target replacement for the ~40 hand-rolled
        `& cmd /c "... 2>&1"` + exit-check pairs across the build scripts
        (promoted from assemble-torch-app.ps1's Invoke-TorchAppNative) —
        migrate call sites incrementally, and only together with a planned
        rebuild of the layers that COPY the touched script.
        ALWAYS normalizes $LASTEXITCODE afterwards so a shielded call can never
        leak a stale exit code out of a green script (the exit-145 class).
    .PARAMETER CommandLine
        The literal command line for cmd.exe /c. Caller quotes embedded paths
        (cmd quoting rules apply, not PowerShell's).
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$Label = '',
        [switch]$Optional,
        [switch]$Quiet
    )
    if (-not $Label) { $Label = ($CommandLine -split '\s+')[0] }
    # /s + a leading space (the exact form proven by assemble-torch-app's
    # Invoke-TorchAppNative, now migrated here): /s forces cmd's deterministic
    # "strip first and last quote" rule, and the leading space keeps a command
    # line that STARTS with a quoted exe path (e.g. "C:\...\python.exe" args)
    # from being re-interpreted under cmd's two-quote heuristic. Behavior-neutral
    # for the pre-existing callers (ffmpeg/iree/litert-lm sites all carry more
    # than two quote chars once PowerShell wraps the argument, so they already
    # took the strip-first-and-last path).
    $out = & cmd.exe /s /c " $CommandLine 2>&1"
    $code = $LASTEXITCODE
    if (-not $Quiet) { $out | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0) {
        if ($Optional) {
            Write-Warning "[$Label] exited $code (optional step; continuing)"
        } else {
            $global:LASTEXITCODE = $code
            throw "[$Label] failed (exit $code)"
        }
    }
    $global:LASTEXITCODE = 0
    return $out
}

Export-ModuleMember -Function Invoke-ShieldedNative
