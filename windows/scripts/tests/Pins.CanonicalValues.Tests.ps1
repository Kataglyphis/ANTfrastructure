#requires -Version 7.0
# Pins values a mechanical edit could quietly change: the CUDA arch set and the merge builder's version ARGs.


Describe 'canonical pin values (backlog #58, #60)' {

    $repoRoot = Get-RepoRoot
    $versionsEnv = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'

    # The canonical parser, never a divergent regex, reads the source of truth.
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
        # Never trimmed as a speed lever: the set changes only with versions.env and this line together.
        Assert-Equal '86;87;89;120' (Get-Pin 'CUDA_ARCHITECTURES') `
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
        # toolchain-builder's ARG defaults feed Build-ToolchainAll.ps1's precedence, so a stale literal would win.
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
        # Rot guard: a restructured ARG block matching nothing would pass vacuously.
        Assert-True ($checked -ge 8) "expected >=8 comparable version ARGs in Dockerfile.media-merge-builder, matched $checked — has the ARG block moved?"
        Assert-Equal 0 $drift.Count ("merge-builder ARG defaults drifted from versions.env: " + ($drift -join '; '))
    }
}
