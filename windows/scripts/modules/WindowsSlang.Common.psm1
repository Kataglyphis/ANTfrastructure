# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Twin of linux/scripts/lib/slang-compile.sh, keep them in step: see docs/slang-shader-compilation.md

# Module scope does not inherit the caller's, and Write-Error must terminate: a missing slangc is never a silent skip.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Combined-WGSL emit guard: see docs/slang-shader-compilation.md § The combined-emit outcomes ---

# In an IO struct (any @builtin/@location member) every member needs one; returns the offenders, empty when valid.
function Test-WgslVaryingsAreLocated {
    param([Parameter(Mandatory)][string]$Path)

    $lines = [IO.File]::ReadAllLines($Path)
    $offenders = @()
    $i = 0
    while ($i -lt $lines.Count) {
        $head = [regex]::Match($lines[$i], '^struct\s+([A-Za-z_]\w*)')
        $i++
        if (-not $head.Success) { continue }
        if ($i -lt $lines.Count -and $lines[$i].Trim() -eq '{') { $i++ }

        $members = @()
        while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('}')) {
            $m = [regex]::Match($lines[$i], '^\s*((?:@\w+\([^)]*\)\s*)*)([A-Za-z_]\w*)\s*:\s*\S.*?,?\s*$')
            if ($m.Success) {
                $members += [pscustomobject]@{
                    Line  = $i + 1
                    Attrs = $m.Groups[1].Value
                    Text  = $lines[$i]
                }
            }
            $i++
        }

        $isIoStruct = @($members | Where-Object { $_.Attrs -match '@builtin\(|@location\(' }).Count -gt 0
        if (-not $isIoStruct) { continue }
        foreach ($member in $members) {
            if ($member.Attrs -notmatch '@builtin\(|@location\(') {
                $offenders += "$($member.Line): struct $($head.Groups[1].Value): $($member.Text.Trim())"
            }
        }
    }
    return , $offenders
}

# MAJOR.MINOR only; an unparseable version counts as new enough, since the emit guard is the backstop.
function Test-SlangcVersionAtLeast {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Have,
          [Parameter(Mandatory)][AllowEmptyString()][string]$Want)

    $haveMatch = [regex]::Match($Have, '^(\d+)\.(\d+)')
    $wantMatch = [regex]::Match($Want, '^(\d+)\.(\d+)')
    if (-not $haveMatch.Success -or -not $wantMatch.Success) { return $true }

    $haveVersion = [version]::new([int]$haveMatch.Groups[1].Value, [int]$haveMatch.Groups[2].Value)
    $wantVersion = [version]::new([int]$wantMatch.Groups[1].Value, [int]$wantMatch.Groups[2].Value)
    return $haveVersion -ge $wantVersion
}

# VULKAN_SDK\Bin (the SDK ships slangc), then PATH; $null when neither has it.
function Resolve-Slangc {
    if ($env:VULKAN_SDK) {
        $candidate = Join-Path $env:VULKAN_SDK 'Bin\slangc.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    $cmd = Get-Command slangc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Every subdirectory on -I, so `import aces` finds common/aces.slang wherever the importer lives.
function Get-SlangIncludeArgument {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SourceDirectory
    )

    # Order matters, the first <name>.slang wins: sorted, top-level common\ first, build tree out; same as the Linux twin.
    $includeArgs = @('-I', $SourceRoot, '-I', $SourceDirectory)
    $buildRoot = Join-Path $SourceRoot 'build'
    $subdirs = Get-ChildItem -Path $SourceRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $buildRoot -and -not $_.FullName.StartsWith($buildRoot + [System.IO.Path]::DirectorySeparatorChar) } |
        Sort-Object -Property FullName
    $commonDir = Join-Path $SourceRoot 'common'
    foreach ($d in @($subdirs | Where-Object { $_.FullName -eq $commonDir })) {
        $includeArgs += '-I'; $includeArgs += $d.FullName
    }
    foreach ($d in @($subdirs | Where-Object { $_.FullName -ne $commonDir })) {
        $includeArgs += '-I'; $includeArgs += $d.FullName
    }
    return , $includeArgs
}

# Full pipeline; -DestinationRoot is the consuming repo root that wgslMap "dst" paths resolve against.
function Invoke-SlangShaderCompile {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$SpirvOutputRoot,
        [string]$WgslOutputRoot,
        [string]$CombinedOutputDir,
        [string]$DestinationRoot = (Get-Location).Path
    )

    if (-not $SpirvOutputRoot) { $SpirvOutputRoot = Join-Path $SourceRoot 'build\spirv' }
    if (-not $WgslOutputRoot) { $WgslOutputRoot = Join-Path $SourceRoot 'build\wgsl' }
    if (-not $CombinedOutputDir) { $CombinedOutputDir = Join-Path $SourceRoot 'build' }

    if (-not (Test-Path $SourceRoot)) {
        Write-Host "[WARN] Slang shader directory not found: $SourceRoot - skipping"
        return
    }

    if (-not (Test-Path $ManifestPath)) {
        # Contract (bash twin): exit 2 - a missing prerequisite, never a silent skip.
        Write-Error "Shader manifest not found: $ManifestPath"
        return
    }

    $slangc = Resolve-Slangc
    if (-not $slangc) {
        # Contract (bash twin): exit 2; a warning here once let CI pass green with no shaders.
        Write-Error 'slangc.exe not found in VULKAN_SDK or PATH. Install the Vulkan SDK (ships slangc) or add slangc to PATH.'
        return
    }
    Write-Host "[INFO] Using slangc: $slangc"

    $manifestData = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    # Rows flagged "disabled" are kept in the JSON as documentation only.
    $manifestRows = @($manifestData.manifest | Where-Object {
        -not ($_.PSObject.Properties['disabled'] -and $_.disabled)
    })

    # Conservative staleness: any .slang may be imported, and a manifest edit can retarget any output.
    $allSlangFiles = @(Get-ChildItem -Path $SourceRoot -Recurse -File -Filter '*.slang' -ErrorAction SilentlyContinue)
    $newestSource = (($allSlangFiles + @(Get-Item $ManifestPath)) |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc

    $failed = @()
    $compiled = 0

    foreach ($entry in $manifestRows) {
        $srcPath = Join-Path $SourceRoot $entry.file
        if (-not (Test-Path $srcPath)) {
            # A manifest bug: fail the run rather than quietly compile one shader fewer.
            Write-Warning "Manifest references missing file: $srcPath"
            $failed += $srcPath
            continue
        }

        $includeArgs = Get-SlangIncludeArgument -SourceRoot $SourceRoot -SourceDirectory (Split-Path $srcPath -Parent)

        foreach ($target in $entry.targets) {
            $outExt = if ($target -eq 'spirv') { 'spv' } else { 'wgsl' }
            $outDir = if ($target -eq 'spirv') { $SpirvOutputRoot } else { $WgslOutputRoot }
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
            # Mirrors the source subdirectory, so equal entry-point names in different shaders cannot collide.
            $relDir = Split-Path $entry.file -Parent
            $targetOutDir = if ($relDir) { Join-Path $outDir $relDir } else { $outDir }
            if (-not (Test-Path $targetOutDir)) { New-Item -ItemType Directory -Force -Path $targetOutDir | Out-Null }
            $baseName = [IO.Path]::GetFileNameWithoutExtension($entry.file)
            $outFile = Join-Path $targetOutDir "$baseName.$($entry.entry).$outExt"

            $needsCompile = $true
            if (Test-Path $outFile) {
                $outStamp = (Get-Item $outFile).LastWriteTimeUtc
                if ($outStamp -ge $newestSource) {
                    $needsCompile = $false
                    Write-Host "[INFO] Up to date: $outFile"
                } else {
                    Write-Host "[INFO] Stale, recompiling: $outFile"
                }
            }
            if (-not $needsCompile) { continue }

            Write-Host "[INFO] Compiling $($entry.file) ($($entry.entry) / $($entry.stage)) -> $target"
            $slangArgs = @("-target", $target, "-stage", $entry.stage, "-entry", $entry.entry) + $includeArgs + @('-o', $outFile, $srcPath)
            & $slangc $slangArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "slangc failed: $($entry.file) $($entry.entry) -> $target"
                $failed += "$srcPath ($($entry.entry) -> $target)"
            } else {
                $compiled++
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Error ("Slang compilation failed for $($failed.Count) entry point(s):`n  " + ($failed -join "`n  "))
        return
    }

    # --- Combined WGSL emit: all entry points in one file, copied where the manifest's dst names ---
    $wgslFailed = @()
    $wgslInvalid = @()
    $wgslEmitted = 0
    if (-not (Test-Path $CombinedOutputDir)) { New-Item -ItemType Directory -Force -Path $CombinedOutputDir | Out-Null }

    # Below the floor the emit is skipped, never overwriting checked-in WGSL; consumers pin regeneration with a test.
    $minSlangcVersion = if ($manifestData.PSObject.Properties['minSlangcVersionForWgsl']) {
        $manifestData.minSlangcVersionForWgsl
    } else { '' }
    $slangcVersion = (& $slangc -version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    $wgslEmitEnabled = $true
    if ($minSlangcVersion -and -not (Test-SlangcVersionAtLeast -Have $slangcVersion -Want $minSlangcVersion)) {
        $wgslEmitEnabled = $false
        Write-Warning ("slangc $slangcVersion is older than $minSlangcVersion, whose combined (whole-module) WGSL " +
            'emit is the first known-correct one: older builds drop @location(N) from varying structs and produce ' +
            'WGSL that wgpu/naga rejects. SKIPPING the combined WGSL emit - the checked-in Rust-crate WGSL is left ' +
            'untouched. See docs/shader-build-pipeline.md.')
    }

    foreach ($entry in $(if ($wgslEmitEnabled) { @($manifestData.wgslMap) } else { @() })) {
        $srcPath = Join-Path $SourceRoot $entry.src
        if (-not (Test-Path $srcPath)) { continue }

        $includeArgs = Get-SlangIncludeArgument -SourceRoot $SourceRoot -SourceDirectory (Split-Path $srcPath -Parent)

        $tmpOut = Join-Path $CombinedOutputDir "combined_$($entry.out)"
        # No -entry/-stage: Slang emits ALL entry points in one WGSL file.
        & $slangc -target wgsl $includeArgs -o $tmpOut $srcPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Combined WGSL emit failed: $($entry.src)"
            $wgslFailed += $entry.src
            continue
        }

        # The manifest's "_comment" fields say why each patch exists; one matching nothing means slangc's output moved.
        $patchProp = $manifestData.depthTexturePatches.PSObject.Properties[$entry.out]
        if ($patchProp) {
            $wgslText = Get-Content -Path $tmpOut -Raw
            foreach ($p in @($patchProp.Value)) {
                $patched = $wgslText -replace $p.pattern, $p.replacement
                if ($patched -eq $wgslText) {
                    Write-Warning "$($entry.out) depth-texture patch '$($p.pattern)' matched nothing - slangc output may have changed"
                }
                $wgslText = $patched
            }
            Set-Content -Path $tmpOut -Value $wgslText -NoNewline -Encoding utf8
        }

        # Validated before the copy, so a broken regeneration can never be committed silently.
        $offenders = Test-WgslVaryingsAreLocated -Path $tmpOut
        if ($offenders.Count -gt 0) {
            Write-Warning ("[ERROR] $($entry.out): slangc $slangcVersion emitted varying struct member(s) with " +
                "neither @builtin nor @location - that is not valid WGSL and wgpu/naga will reject it. Emit kept " +
                "at $tmpOut; $($entry.dst)/$($entry.out) NOT overwritten:`n  " + ($offenders -join "`n  "))
            $wgslInvalid += $entry.out
            continue
        }

        $dstDir = Join-Path $DestinationRoot $entry.dst
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -Path $tmpOut -Destination (Join-Path $dstDir $entry.out) -Force
        $wgslEmitted++
    }

    if ($wgslFailed.Count -gt 0) {
      Write-Warning ("Combined WGSL emit failed for $($wgslFailed.Count) file(s):`n  " + ($wgslFailed -join "`n  "))
    }

    Write-Host "[INFO] Slang shader compilation finished ($compiled SPIR-V/WGSL artifact(s) + $wgslEmitted combined WGSL file(s))"

    # Fatal but last, so the summary still prints: an invalid emit is a toolchain regression.
    if ($wgslInvalid.Count -gt 0) {
        Write-Error ("$($wgslInvalid.Count) combined WGSL emit(s) had varying struct members without " +
            "@builtin/@location:`n  " + ($wgslInvalid -join "`n  ") +
            "`nNone of them were copied into the destination shader directories. Fix the toolchain (slangc >= " +
            "$minSlangcVersion is known good; this run used $slangcVersion) - do not hand-patch the generated WGSL.")
        return
    }
}

Export-ModuleMember -Function Test-WgslVaryingsAreLocated, Test-SlangcVersionAtLeast, Resolve-Slangc,
    Get-SlangIncludeArgument, Invoke-SlangShaderCompile
