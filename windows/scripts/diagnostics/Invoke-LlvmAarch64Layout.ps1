#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    A/B harness: does a candidate clang-cl compile the frozen #135 AArch64 offenders with the workarounds off?
.DESCRIPTION
    Each case runs baseline/off (must fail), baseline/on (must pass) and candidate/off; a broken control makes it INVALID.
    FIXED licenses the full NINJA_KEEP_GOING=1 census, it does not replace it; the frozen .i files need no MSVC environment.
.PARAMETER Capture
    Build the frozen .i corpus from a configured OpenCV build tree, once per OpenCV bump.
.PARAMETER OpenCvBuildDir
    Capture mode only: the OpenCV build directory holding build.ninja.
.PARAMETER CandidateClangCl
    The compiler under test; omit to run the control arms only, which validates the corpus.
.PARAMETER BaselineClangCl
    Stock clang-cl for the control arms; omitted, the pinned release is downloaded into -WorkDir.
.EXAMPLE
    .\Invoke-LlvmAarch64Layout.ps1 -Capture -OpenCvBuildDir C:\temp\opencv-src\build -CorpusDir C:\bkmnt\out\llvm135-corpus
.EXAMPLE
    .\Invoke-LlvmAarch64Layout.ps1 -CorpusDir .\out\llvm135-corpus -CandidateClangCl D:\llvm-fork\build\bin\clang-cl.exe
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Capture', Mandatory)]
    [switch]$Capture,

    [Parameter(ParameterSetName = 'Capture', Mandatory)]
    [string]$OpenCvBuildDir,

    [Parameter(ParameterSetName = 'Run')]
    [string]$CandidateClangCl = '',

    [Parameter(ParameterSetName = 'Run')]
    [string]$BaselineClangCl = '',

    [string]$CorpusDir = (Join-Path $PSScriptRoot '..\..\..\out\llvm135-corpus'),
    [string]$WorkDir = (Join-Path $env:TEMP 'llvm135-repro'),

    # Keep in step with LLVM_WINDOWS_VERSION: a control arm on another compiler proves nothing about the lane.
    [string]$BaselineLlvmVersion = '23.1.0',

    [string]$Target = 'aarch64-pc-windows-msvc'
)

$ErrorActionPreference = 'Stop'

# One entry per measured failure; ObjectPattern is a regex over ninja targets, and matching nothing fails the capture.
$Cases = @(
    @{
        Id            = 'branch-relax'
        ObjectPattern = 'median_blur\.dispatch\.cpp\.obj$'
        OffFlags      = @('/O2', '/Ob2')
        OnFlags       = @('/O2', '/Ob1')
        # The MC-layer wording; the missing source location is the signature.
        Expect        = 'fixup value out of range'
        Ref           = '#135 (2) BranchRelaxation estimate short: tbnz ~150 B out of reach in cv::cpu_baseline::medianBlur'
    }
    @{
        Id            = 'branch-relax-calib'
        ObjectPattern = 'multiview_calibration\.cpp\.obj$'
        OffFlags      = @('/O2', '/Ob2')
        OnFlags       = @('/O2', '/Ob1')
        Expect        = 'fixup value out of range'
        Ref           = '#135 (2) second offender found by the NINJA_KEEP_GOING=1 census'
    }
    @{
        Id            = 'jump-table'
        ObjectPattern = 'protobuf.*descriptor\.cc\.obj$'
        OffFlags      = @('/O2', '/Ob2')
        OnFlags       = @('/O2', '/Ob2', '-Xclang', '-target-feature', '-Xclang', '+force-32bit-jump-tables')
        Expect        = 'value evaluated as \d+ is out of range'
        Ref           = '#135 (1) AArch64CompressJumpTables picks 1-byte entries off a short estimate (ceiling 255*4 = 1020 B)'
    }
    @{
        Id            = 'jump-table-reflection'
        ObjectPattern = 'protobuf.*generated_message_reflection\.cc\.obj$'
        OffFlags      = @('/O2', '/Ob2')
        OnFlags       = @('/O2', '/Ob2', '-Xclang', '-target-feature', '-Xclang', '+force-32bit-jump-tables')
        Expect        = 'value evaluated as \d+ is out of range'
        Ref           = '#135 (1) same defect, second protobuf TU'
    }
    @{
        Id            = 'jump-table-wireformat'
        ObjectPattern = 'protobuf.*wire_format\.cc\.obj$'
        OffFlags      = @('/O2', '/Ob2')
        OnFlags       = @('/O2', '/Ob2', '-Xclang', '-target-feature', '-Xclang', '+force-32bit-jump-tables')
        Expect        = 'value evaluated as \d+ is out of range'
        Ref           = '#135 (1) same defect, third protobuf TU'
    }
)

# Flags are derived from the captured ninja command; both workaround spellings must go, or the off arm is not off.
function Split-CommandLine {
    param([Parameter(Mandatory)][string]$Line)
    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuote = $false
    $has = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; $has = $true; continue }
        if (-not $inQuote -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($has) { [void]$tokens.Add($current.ToString()); [void]$current.Clear(); $has = $false }
            continue
        }
        [void]$current.Append($ch); $has = $true
    }
    if ($has) { [void]$tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

function Get-CodegenFlags {
    param([Parameter(Mandatory)][string[]]$Tokens)

    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    # The caller supplies the compiler, so skip every leading executable.
    while ($i -lt $Tokens.Count -and $Tokens[$i] -match '\.exe$') { $i++ }

    while ($i -lt $Tokens.Count) {
        $t = $Tokens[$i]
        $i++

        # The workaround spellings, the separated -mllvm form included.
        if ($t -eq '-mllvm') {
            if ($i -lt $Tokens.Count -and $Tokens[$i] -match 'compress-jump-tables') { $i++; continue }
            if ($i -lt $Tokens.Count -and $Tokens[$i] -match 'inline-threshold') { $i++; continue }
            [void]$out.Add($t); continue
        }
        if ($t -match 'aarch64-enable-compress-jump-tables') { continue }
        # -Xclang -target-feature -Xclang +force-32bit-jump-tables : four tokens.
        if ($t -eq '-Xclang' -and ($i + 2) -lt $Tokens.Count -and
            $Tokens[$i] -eq '-target-feature' -and $Tokens[$i + 2] -match 'force-32bit-jump-tables') {
            $i += 3; continue
        }

        # Optimisation and inlining are set per-arm.
        if ($t -match '^[-/]O[0-9dxs]') { continue }
        if ($t -match '^[-/]Ob[0-3]$') { continue }

        # Baked into the .i; the separated /D NAME form must drop both tokens, or clang-cl reads NAME as an input.
        if ($t -cmatch '^[-/](I|D)$') { $i++; continue }
        if ($t -cmatch '^[-/](I|D)') { continue }
        if ($t -match '^-imsvc') { if ($t -ceq '-imsvc') { $i++ }; continue }
        if ($t -cmatch '^[-/]FI') { if ($t -ceq '/FI' -or $t -ceq '-FI') { $i++ }; continue }

        # -cmatch: case-insensitive -match would also swallow /fp:precise, a real codegen flag.
        if ($t -match '^-clang:-M') { continue }
        if ($t -cmatch '^[-/]F[odip]') { continue }
        if ($t -ceq '-c' -or $t -ceq '/c' -or $t -ceq '--') { continue }
        if ($t -match '\.(cpp|cc|cxx|c)$') { continue }

        [void]$out.Add($t)
    }

    # Pin the target; a plain return, since `return ,$x` leaves the caller's @() one Object[] instead of flags.
    $flags = @($out | Where-Object { $_ -notmatch '^--target=' })
    return @('--target=' + $Target) + $flags
}

function Resolve-NinjaCommand {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$ObjectPattern
    )
    Push-Location $BuildDir
    try {
        $targets = @(& ninja -t targets all 2>$null | ForEach-Object { ($_ -split ':')[0] } |
                Where-Object { $_ -match $ObjectPattern })
        if ($targets.Count -eq 0) {
            throw ("no ninja target matches /$ObjectPattern/ in $BuildDir -- OpenCV moved or renamed the TU. " +
                'Re-take the census with NINJA_KEEP_GOING=1 and update $Cases before trusting any verdict.')
        }
        if ($targets.Count -gt 1) {
            throw "ambiguous: /$ObjectPattern/ matched $($targets.Count) targets ($($targets -join ', ')). Tighten the pattern."
        }
        $target = $targets[0]
        $cmd = @(& ninja -t commands $target 2>$null | Where-Object { $_ -match [regex]::Escape($target) } | Select-Object -Last 1)
        if ($cmd.Count -eq 0) { throw "ninja -t commands returned nothing for $target" }
        return [pscustomobject]@{ Target = $target; Command = $cmd[0] }
    } finally { Pop-Location }
}

# Capture
function Invoke-Capture {
    if (-not (Test-Path (Join-Path $OpenCvBuildDir 'build.ninja'))) {
        throw "no build.ninja in $OpenCvBuildDir -- point -OpenCvBuildDir at a CONFIGURED OpenCV build tree."
    }
    $null = New-Item -ItemType Directory -Force -Path $CorpusDir

    $captureClang = $BaselineClangCl
    if (-not $captureClang) {
        $onPath = @(Get-Command clang-cl.exe -ErrorAction SilentlyContinue)
        if ($onPath.Count -gt 0) { $captureClang = $onPath[0].Source }
    }
    if (-not $captureClang) { throw 'capture needs a clang-cl on PATH or -BaselineClangCl (preprocessing only; any version will do).' }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($case in $Cases) {
        Write-Host "capture: $($case.Id)"
        $resolved = Resolve-NinjaCommand -BuildDir $OpenCvBuildDir -ObjectPattern $case.ObjectPattern
        $tokens = Split-CommandLine -Line $resolved.Command

        # Preprocess with the original command, so every -I/-D/-FI the lane passes applies exactly once, here.
        $ppArgs = [System.Collections.Generic.List[string]]::new()
        $source = ''
        $i = 0
        while ($i -lt $tokens.Count -and $tokens[$i] -match '\.exe$') { $i++ }
        while ($i -lt $tokens.Count) {
            $t = $tokens[$i]; $i++
            # -cmatch so /fp:precise survives; -I, -D and /FI stay, since preprocessing is where they belong.
            if ($t -cmatch '^[-/]F[od]') { continue }
            if ($t -match '^-clang:-M') { continue }
            if ($t -ceq '-c' -or $t -ceq '/c' -or $t -ceq '--') { continue }
            if ($t -match '\.(cpp|cc|cxx|c)$') { $source = $t; continue }
            [void]$ppArgs.Add($t)
        }
        if (-not $source) { throw "could not find the source path in the ninja command for $($resolved.Target)" }

        $iPath = Join-Path $CorpusDir ("$($case.Id).i")
        [void]$ppArgs.Add('/P')
        [void]$ppArgs.Add("/Fi$iPath")

        Push-Location $OpenCvBuildDir
        try {
            & $captureClang @ppArgs $source 2>&1 | Where-Object { $_ -match 'error' } | ForEach-Object { Write-Warning "$_" }
            if ($LASTEXITCODE -ne 0) { throw "preprocess failed for $source (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
        if (-not (Test-Path $iPath)) { throw "preprocess produced no $iPath" }

        [void]$entries.Add([pscustomobject]@{
                Id           = $case.Id
                Target       = $resolved.Target
                Source       = $source
                Ref          = $case.Ref
                Expect       = $case.Expect
                OffFlags     = $case.OffFlags
                OnFlags      = $case.OnFlags
                CodegenFlags = Get-CodegenFlags -Tokens $tokens
                Preprocessed = [System.IO.Path]::GetFileName($iPath)
                Sha256       = (Get-FileHash -Path $iPath -Algorithm SHA256).Hash
                Bytes        = (Get-Item $iPath).Length
                FullCommand  = $resolved.Command
            })
        Write-Host ("  -> {0}  ({1:N1} MB)" -f $entries[-1].Preprocessed, ($entries[-1].Bytes / 1MB))
    }

    $manifest = [pscustomobject]@{
        SchemaVersion  = 1
        Target         = $Target
        CapturedWith   = (& $captureClang --version 2>$null | Select-Object -First 1)
        OpenCvBuildDir = $OpenCvBuildDir
        Cases          = $entries
    }
    $manifestPath = Join-Path $CorpusDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
    Write-Host ''
    Write-Host "corpus written: $CorpusDir  ($($entries.Count) cases)"
    Write-Host 'The .i files are the durable artefact -- they make every later run independent of'
    Write-Host 'an OpenCV tree, an MSVC environment and a container. Re-capture after an OpenCV bump.'
}

# Baseline provisioning
function Get-BaselineClangCl {
    if ($BaselineClangCl) {
        if (-not (Test-Path $BaselineClangCl)) { throw "-BaselineClangCl not found: $BaselineClangCl" }
        return $BaselineClangCl
    }
    $root = Join-Path $WorkDir "clang+llvm-$BaselineLlvmVersion-x86_64-pc-windows-msvc"
    $exe = Join-Path $root 'bin\clang-cl.exe'
    if (Test-Path $exe) { return $exe }

    $null = New-Item -ItemType Directory -Force -Path $WorkDir
    # %2B, not '+': the unencoded asset URL 404s.
    $url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$BaselineLlvmVersion/clang%2Bllvm-$BaselineLlvmVersion-x86_64-pc-windows-msvc.tar.xz"
    $archive = Join-Path $WorkDir "clang+llvm-$BaselineLlvmVersion-x86_64-pc-windows-msvc.tar.xz"
    if (-not (Test-Path $archive)) {
        Write-Host "downloading stock LLVM $BaselineLlvmVersion (one-time, ~700 MB) ..."
        Invoke-WebRequest -Uri $url -OutFile $archive -MaximumRetryCount 3 -RetryIntervalSec 5
    }
    Write-Host 'extracting ...'
    & tar.exe -xf $archive -C $WorkDir
    $global:LASTEXITCODE = 0
    if (-not (Test-Path $exe)) { throw "extracted archive has no $exe -- the upstream layout changed." }
    return $exe
}

# Run
function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string]$ClangCl,
        [Parameter(Mandatory)][string[]]$Flags,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$ObjPath
    )
    # Not $args: shadowing that automatic variable in a param() function silently loses arguments.
    $argv = @($Flags) + @('/TP', '/c', "/Fo$ObjPath", $InputPath)
    $output = & $ClangCl @argv 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n")
    }
}

function Invoke-Run {
    $manifestPath = Join-Path $CorpusDir 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        throw ("no corpus at $CorpusDir. Build one first: -Capture -OpenCvBuildDir <opencv build dir>. " +
            'Without the real TUs there is nothing to measure -- a synthetic reproducer is not evidence here, ' +
            'because a 148-byte miss flips on any perturbation.')
    }
    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Target -ne $Target) {
        throw "corpus was captured for $($manifest.Target) but -Target is $Target."
    }

    $baseline = Get-BaselineClangCl
    Write-Host "baseline : $baseline"
    Write-Host "           $((& $baseline --version 2>$null | Select-Object -First 1))"
    if ($CandidateClangCl) {
        if (-not (Test-Path $CandidateClangCl)) { throw "-CandidateClangCl not found: $CandidateClangCl" }
        Write-Host "candidate: $CandidateClangCl"
        Write-Host "           $((& $CandidateClangCl --version 2>$null | Select-Object -First 1))"
    } else {
        Write-Host 'candidate: (none -- control arms only; this validates the corpus, it settles nothing)'
    }
    Write-Host ''

    $objDir = Join-Path $WorkDir 'obj'
    $null = New-Item -ItemType Directory -Force -Path $objDir
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($case in $manifest.Cases) {
        $iPath = Join-Path $CorpusDir $case.Preprocessed
        if (-not (Test-Path $iPath)) { throw "corpus incomplete: $iPath missing" }
        $actual = (Get-FileHash -Path $iPath -Algorithm SHA256).Hash
        if ($actual -ne $case.Sha256) {
            throw "corpus tampered: $($case.Preprocessed) hashes $actual, manifest says $($case.Sha256)."
        }

        $flags = @($case.CodegenFlags)
        $offArm = Invoke-Arm -ClangCl $baseline -Flags ($flags + @($case.OffFlags)) `
            -InputPath $iPath -ObjPath (Join-Path $objDir "$($case.Id).baseline-off.obj")
        $onArm = Invoke-Arm -ClangCl $baseline -Flags ($flags + @($case.OnFlags)) `
            -InputPath $iPath -ObjPath (Join-Path $objDir "$($case.Id).baseline-on.obj")

        $reproduced = ($offArm.ExitCode -ne 0) -and ($offArm.Output -match $case.Expect)
        $suppressed = ($onArm.ExitCode -eq 0)

        $verdict = ''
        $candArm = $null
        if (-not $reproduced) {
            $verdict = 'INVALID-NO-REPRO'
        } elseif (-not $suppressed) {
            $verdict = 'INVALID-WORKAROUND-DEAD'
        } elseif (-not $CandidateClangCl) {
            $verdict = 'CONTROL-OK'
        } else {
            $candArm = Invoke-Arm -ClangCl $CandidateClangCl -Flags ($flags + @($case.OffFlags)) `
                -InputPath $iPath -ObjPath (Join-Path $objDir "$($case.Id).candidate-off.obj")
            if ($candArm.ExitCode -eq 0) { $verdict = 'FIXED' }
            elseif ($candArm.Output -match $case.Expect) { $verdict = 'NOT-FIXED' }
            else { $verdict = 'INCONCLUSIVE' }
        }

        # Precomputed: statement-valued hashtable entries parse differently across hosts.
        $candExit = $null
        $candTail = ''
        if ($null -ne $candArm) {
            $candExit = $candArm.ExitCode
            $candTail = (@($candArm.Output -split "`n" | Where-Object { $_ -match 'error' } | Select-Object -First 3)) -join ' | '
        }
        $baseTail = (@($offArm.Output -split "`n" | Where-Object { $_ -match 'error' } | Select-Object -First 3)) -join ' | '

        [void]$results.Add([pscustomobject]@{
                Id            = $case.Id
                Ref           = $case.Ref
                Verdict       = $verdict
                BaselineOff   = $offArm.ExitCode
                BaselineOn    = $onArm.ExitCode
                CandidateOff  = $candExit
                Reproduced    = $reproduced
                Suppressed    = $suppressed
                CandidateTail = $candTail
                BaselineTail  = $baseTail
            })
    }

    Write-Host '=== per-case ==='
    $results | Format-Table Id, Verdict, BaselineOff, BaselineOn, CandidateOff -AutoSize | Out-String | Write-Host

    $invalid = @($results | Where-Object { $_.Verdict -like 'INVALID*' })
    $notFixed = @($results | Where-Object { $_.Verdict -eq 'NOT-FIXED' })
    $inconclusive = @($results | Where-Object { $_.Verdict -eq 'INCONCLUSIVE' })
    $fixed = @($results | Where-Object { $_.Verdict -eq 'FIXED' })

    Write-Host '=== verdict ==='
    if ($invalid.Count -gt 0) {
        foreach ($r in $invalid) { Write-Host "  $($r.Id): $($r.Verdict) -- $($r.BaselineTail)" }
        Write-Host ''
        Write-Host 'HARNESS INVALID. The control arms did not behave, so no statement about the'
        Write-Host 'candidate is supported by this run -- including a green one. Fix the corpus'
        Write-Host '(re-capture against the current OpenCV tree) before reading anything else.'
        $overall = 'INVALID'
    } elseif (-not $CandidateClangCl) {
        Write-Host "  corpus validated: $($results.Count)/$($results.Count) cases reproduce the abort and are suppressed by the shipped workaround."
        Write-Host '  Re-run with -CandidateClangCl to test a compiler.'
        $overall = 'CONTROL-OK'
    } elseif ($notFixed.Count -gt 0 -or $inconclusive.Count -gt 0) {
        foreach ($r in ($notFixed + $inconclusive)) { Write-Host "  $($r.Id): $($r.Verdict) -- $($r.CandidateTail)" }
        Write-Host ''
        Write-Host 'The candidate does NOT retire the workaround. Keep both settings in'
        Write-Host 'Build-OpencvFromSource.ps1.'
        $overall = 'NOT-FIXED'
    } else {
        Write-Host "  all $($fixed.Count) cases compile clean on the candidate with the workaround OFF."
        Write-Host ''
        Write-Host 'NECESSARY, NOT SUFFICIENT. This is a census of the TUs that failed in'
        Write-Host 'August 2026, frozen. The ceiling is a property of what the inliner produces,'
        Write-Host 'so a new offender is one OpenCV source change away. Before removing anything'
        Write-Host 'from Build-OpencvFromSource.ps1, run the full container census:'
        Write-Host ''
        Write-Host '    NINJA_KEEP_GOING=1, both workarounds disabled, all ~1,870 objects in one'
        Write-Host '    run -- that is what closed the offender list at two in the first place.'
        $overall = 'FIXED'
    }

    $summary = [pscustomobject]@{
        Overall      = $overall
        Target       = $Target
        Baseline     = $baseline
        Candidate    = $CandidateClangCl
        Cases        = $results
    }
    $outPath = Join-Path $WorkDir 'verdict.json'
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding utf8
    Write-Host ''
    Write-Host "machine-readable: $outPath"
    if ($overall -eq 'INVALID') { exit 2 }
    if ($overall -eq 'NOT-FIXED') { exit 1 }
}

if ($Capture) { Invoke-Capture } else { Invoke-Run }
