#requires -Version 7.0
# Backlog #58 + #60: pin the values that a mechanical edit could quietly change.
#
# #58 — CUDA_ARCHITECTURES. The owner's standing directive is that
# `80;86;89;90` is NEVER trimmed, in any build, including dev iterations. Three
# copies of that string exist: versions.env (source of truth),
# Dockerfile.media-builder's ARG default, and a code fallback in
# WindowsSourceBuild.Cuda.psm1. Only the CODE FALLBACK was asserted — and
# SourceBuild.Resolve.Tests.ps1 proves in the very next test that the env value
# overrides it. So trimming versions.env to a single arch kept the whole suite
# green, and `sync_versions.py --write` would then have propagated the trim into
# the Dockerfile. The failure is silent: a working build that simply lacks arch
# coverage. This asserts the PIN.
#
# #60 — Dockerfile.media-merge-builder's version ARGs. BuildKit.TwinParity
# hardcodes the media-BUILDER path, so the MERGE builder is opened by no test at
# all, and PinParity never reads any Dockerfile. That is exactly the stage where
# the documented "~8 versions.env-bump breaks" landed.


Describe 'canonical pin values (backlog #58, #60)' {

    $repoRoot = Get-RepoRoot
    $versionsEnv = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'

    # Thin wrapper over the CANONICAL parser (#126, 2026-08-21): the previous
    # hand-rolled regex loop handled no quoting/comments/continuations — a
    # suite whose purpose is "pin the values a mechanical edit could quietly
    # change" must not read the source of truth with a divergent parser.
    $script:canonicalPins = ConvertFrom-VersionsEnv -Path $versionsEnv
    function Get-Pin {
        param([string]$Name)
        if ($script:canonicalPins.Contains($Name)) { return $script:canonicalPins[$Name] }
        return $null
    }

    It 'reads versions.env at all (guards against a dead scanner)' {
        Assert-True (Test-Path $versionsEnv) "versions.env not found at $versionsEnv"
        Assert-True ([bool](Get-Pin 'CUDA_VERSION')) 'expected CUDA_VERSION to parse from versions.env'
    }

    It 'keeps CUDA_ARCHITECTURES at the full owner-mandated set (NEVER trim)' {
        # Owner directive: keep 80;86;89;90 in ALL builds including dev
        # iterations; arch reduction is explicitly banned as a speed lever.
        Assert-Equal '80;86;89;90' (Get-Pin 'CUDA_ARCHITECTURES') `
            'versions.env CUDA_ARCHITECTURES was trimmed — this is the SOURCE OF TRUTH the container actually builds with, and trimming it is silent (a green build with missing arch coverage).'
    }

    It 'keeps the Dockerfile ARG default for CUDA_ARCHITECTURES in step with the pin' {
        $df = Join-Path $repoRoot 'windows\Dockerfile.media-builder'
        Assert-True (Test-Path $df) "missing $df"
        $argLine = @(Get-Content $df | Where-Object { $_ -match '^\s*ARG\s+CUDA_ARCHITECTURES\s*=' })
        Assert-True ($argLine.Count -ge 1) 'Dockerfile.media-builder must declare ARG CUDA_ARCHITECTURES'
        foreach ($l in $argLine) {
            $val = ($l -replace '^\s*ARG\s+CUDA_ARCHITECTURES\s*=\s*', '').Trim().Trim('"')
            Assert-Equal (Get-Pin 'CUDA_ARCHITECTURES') $val 'Dockerfile ARG default drifted from versions.env'
        }
    }

    It 'keeps every version ARG default in the merge + toolchain Dockerfiles equal to versions.env (backlog #60, extended 2026-08-21)' {
        # toolchain-builder joined 2026-08-21: its ARG defaults feed the
        # versions.env precedence rule in Build-ToolchainAll.ps1 (a stale
        # Dockerfile literal would now beat the fresh file for that key).
        $dfFiles = @('Dockerfile.media-merge-builder', 'Dockerfile.toolchain-builder') | ForEach-Object { Join-Path $repoRoot ('windows\' + $_) }
        $checked = 0
        $drift = @()
        foreach ($df in $dfFiles) {
        Assert-True (Test-Path $df) "missing $df"
        foreach ($line in (Get-Content $df)) {
            if ($line -notmatch '^\s*ARG\s+([A-Z0-9_]+)\s*=\s*(.+?)\s*$') { continue }
            $name = $Matches[1]
            $val = $Matches[2].Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($val)) { continue }   # ARG X="" is a pass-through
            $pin = Get-Pin $name
            if ($null -eq $pin) { continue }                        # not a versions.env key
            $checked++
            if ($pin -ne $val) { $drift += "$name (Dockerfile=$val, versions.env=$pin)" }
        }
        }
        # Rot guard: if the ARG block is ever restructured so nothing matches,
        # this test would pass vacuously — which is how #60 existed at all.
        Assert-True ($checked -ge 8) "expected >=8 comparable version ARGs in Dockerfile.media-merge-builder, matched $checked — has the ARG block moved?"
        Assert-Equal 0 $drift.Count ("merge-builder ARG defaults drifted from versions.env: " + ($drift -join '; '))
    }
}
