# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# WindowsSlang.Common - generic "compile a Slang shader tree to SPIR-V and WGSL"
# driver. The Windows twin of linux/scripts/lib/slang-compile.sh; the two are
# behaviourally identical and must be kept in step.
#
# This module is project-agnostic: the shader list, entry points, stages,
# targets, the combined-WGSL copy map and the post-emit patch table are all
# data, read from the manifest JSON the caller points at. A consuming script
# keeps only paths - manifest, Slang source root, the SPIR-V/WGSL output roots
# and the repository root the manifest's wgslMap destinations resolve against.
#
# Manifest schema (keys starting with '_' are documentation and ignored):
#   manifest[]              { file, entry, stage, targets[], disabled? }
#                           one row per (entry point, target); 'file' is
#                           relative to the source root, 'targets' is any mix of
#                           "spirv" and "wgsl", and disabled rows are kept as
#                           documentation without being compiled
#   wgslMap[]               { src, out, dst } - combined (whole-module) WGSL emit
#   depthTexturePatches     { "<out>": [ { pattern, replacement } ] } - post-emit
#                           regex patches applied to that combined emit
#   minSlangcVersionForWgsl "MAJOR.MINOR" toolchain floor for the combined emit
#
# Staleness: an output is reused only when it is newer than its source AND every
# .slang file under the source tree AND the manifest file itself (conservative -
# an import or manifest edit rebuilds every dependent).
#
# Failure model: every fatal condition is reported with Write-Error. The module
# sets $ErrorActionPreference = 'Stop' in its own scope (module scope does not
# inherit the caller's), so those are terminating errors that abort the calling
# script AND its caller - a missing slangc must never be a silent skip, which
# once let CI pass green with no compiled shaders at all. The exit codes named
# in the comments below are the contract the bash twin implements literally.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Combined-WGSL emit correctness guard.
#
# WGSL requires every non-builtin member of an inter-stage (varying) struct to
# carry @location(N). slangc 2026.1-52-gc8ddf20bb - the build in Vulkan SDK
# 1.4.341.1, i.e. the ContainerHub Linux image - drops that attribute in the
# COMBINED emit (no -entry/-stage) while emitting it correctly per entry point,
# so a regeneration on that toolchain silently produced WGSL naga rejects.
# 2026.8 is correct on both Windows and Linux. Two defences, both needed:
#   1. the manifest's minSlangcVersionForWgsl floor - below it we do not emit at
#      all, so the (correct) checked-in WGSL is never overwritten;
#   2. Test-WgslVaryingsAreLocated - at or above the floor we emit and then
#      verify, so ANY future emit regression fails the build instead of being
#      copied.
# The same rule is reimplemented in linux/scripts/lib/slang-compile.sh - keep
# the two in step, and with whatever test the consuming project pins it with
# (here: BuildIntegrity.CheckedInWgslVaryingStructsCarryLocations).
# ---------------------------------------------------------------------------

# A struct with at least one @builtin/@location member is an IO struct; every
# member of it must then carry one of those attributes. Returns the offending
# "<line>: struct <name>: <text>" descriptions (empty array = valid).
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

# Compares the leading MAJOR.MINOR only. slangc prints e.g. "2026.8" or
# "2026.1-52-gc8ddf20bb". An unparseable version is treated as new enough: the
# emit guard above is the backstop, and refusing to compile on an unrecognised
# version string would be worse.
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

# slangc is resolved from VULKAN_SDK\Bin, then PATH. The Vulkan SDK ships slangc
# (verified: VulkanSDK 1.4.350.0). Returns $null when neither has it.
function Resolve-Slangc {
    if ($env:VULKAN_SDK) {
        $candidate = Join-Path $env:VULKAN_SDK 'Bin\slangc.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    $cmd = Get-Command slangc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# slangc resolves `import <name>` to <name>.slang on the -I paths. Add the
# source root, the importing shader's own directory and every subdirectory so
# `import aces` finds common/aces.slang regardless of where the importing
# shader lives.
function Get-SlangIncludeArgument {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SourceDirectory
    )

    # ORDER IS LOAD-BEARING. `import <name>` resolves to the FIRST <name>.slang
    # on the -I list, so two modules sharing a basename resolve by whatever
    # order the directory walk happens to produce. Kept in lockstep with the
    # Linux twin (_slang_compile_collect_subdirs in linux/scripts/lib/
    # slang-compile.sh), where an unsorted walk made common/noise.slang vs
    # compute/noise.slang resolve one way locally and the other way on CI -
    # failing every clang lane with "undefined identifier 'snoise'".
    #
    #   1. sort, so the answer is reproducible;
    #   2. hoist a top-level common\ ahead of the rest - "shared modules live in
    #      common/" is this driver's standing assumption, and the consumer side
    #      documents the same "common/ preference" when it resolves imports.
    #
    # The generated build tree is excluded: it holds no .slang sources and can
    # only add ambiguity.
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

# ---------------------------------------------------------------------------
# Full pipeline
# ---------------------------------------------------------------------------
# Compiles every enabled manifest row to its targets (skipping up-to-date
# outputs), then performs the combined WGSL emit for every wgslMap entry.
#
# Paths are all the consumer has to supply:
#   -ManifestPath        manifest JSON
#   -SourceRoot          root of the .slang tree
#   -SpirvOutputRoot     'spirv' target output root  (<SourceRoot>\build\spirv)
#   -WgslOutputRoot      'wgsl' target output root   (<SourceRoot>\build\wgsl)
#   -CombinedOutputDir   staging dir for the combined emit (<SourceRoot>\build)
#   -DestinationRoot     root the wgslMap "dst" paths resolve against, i.e. the
#                        consuming repository root
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
        # Contract (bash twin): exit 2 - see above. A missing slangc that only
        # warned once let CI pass green with no shaders at all.
        Write-Error 'slangc.exe not found in VULKAN_SDK or PATH. Install the Vulkan SDK (ships slangc) or add slangc to PATH.'
        return
    }
    Write-Host "[INFO] Using slangc: $slangc"

    $manifestData = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    # Rows flagged "disabled" are kept in the JSON as documentation only.
    $manifestRows = @($manifestData.manifest | Where-Object {
        -not ($_.PSObject.Properties['disabled'] -and $_.disabled)
    })

    # Every .slang file is a potential import dependency, and a manifest edit can
    # retarget any output (conservative staleness).
    $allSlangFiles = @(Get-ChildItem -Path $SourceRoot -Recurse -File -Filter '*.slang' -ErrorAction SilentlyContinue)
    $newestSource = (($allSlangFiles + @(Get-Item $ManifestPath)) |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc

    $failed = @()
    $compiled = 0

    foreach ($entry in $manifestRows) {
        $srcPath = Join-Path $SourceRoot $entry.file
        if (-not (Test-Path $srcPath)) {
            # A manifest row whose source is gone is a manifest bug: fail the
            # run rather than quietly compiling one shader fewer.
            Write-Warning "Manifest references missing file: $srcPath"
            $failed += $srcPath
            continue
        }

        $includeArgs = Get-SlangIncludeArgument -SourceRoot $SourceRoot -SourceDirectory (Split-Path $srcPath -Parent)

        foreach ($target in $entry.targets) {
            $outExt = if ($target -eq 'spirv') { 'spv' } else { 'wgsl' }
            $outDir = if ($target -eq 'spirv') { $SpirvOutputRoot } else { $WgslOutputRoot }
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
            # Mirror the source subdirectory under the target's output root so
            # distinct shaders with the same entry-point name do not collide.
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

    # -----------------------------------------------------------------------
    # Combined WGSL emit: compile each wgslMap source WITHOUT -entry/-stage to
    # get all entry points in one WGSL file, then copy it to the destination
    # shader directory the manifest names (e.g. a Rust crate's shaders folder,
    # so include_str! picks up the Slang-emitted WGSL).
    # -----------------------------------------------------------------------
    $wgslFailed = @()
    $wgslInvalid = @()
    $wgslEmitted = 0
    if (-not (Test-Path $CombinedOutputDir)) { New-Item -ItemType Directory -Force -Path $CombinedOutputDir | Out-Null }

    # Toolchain floor: below it slangc's combined emit is known to drop varying
    # @location attributes, so skip the emit entirely rather than overwrite the
    # checked-in WGSL with output naga rejects. Regenerating after a .slang edit
    # then needs a newer slangc - the consuming project is expected to pin that
    # with a test (here:
    # BuildIntegrity.CheckedInWgslIsNotOlderThanItsSlangSource) so a skipped and
    # forgotten regeneration fails.
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

        # Post-emit patch table (depthTexturePatches): why each patch exists is
        # documented in the "_comment" fields next to the patterns in the
        # manifest. A patch that matches nothing is reported loudly - it means
        # slangc's output shape changed under us.
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

        # Reject a structurally invalid emit BEFORE it can overwrite the checked-in
        # file, so a broken regeneration can never be committed silently.
        $offenders = Test-WgslVaryingsAreLocated -Path $tmpOut
        if ($offenders.Count -gt 0) {
            Write-Warning ("[ERROR] $($entry.out): slangc $slangcVersion emitted varying struct member(s) with " +
                "neither @builtin nor @location - that is not valid WGSL and wgpu/naga will reject it. Emit kept " +
                "at $tmpOut; $($entry.dst)/$($entry.out) NOT overwritten:`n  " + ($offenders -join "`n  "))
            $wgslInvalid += $entry.out
            continue
        }

        # Copy to the destination shader directory (replaces hand-written WGSL).
        $dstDir = Join-Path $DestinationRoot $entry.dst
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -Path $tmpOut -Destination (Join-Path $dstDir $entry.out) -Force
        $wgslEmitted++
    }

    if ($wgslFailed.Count -gt 0) {
      Write-Warning ("Combined WGSL emit failed for $($wgslFailed.Count) file(s):`n  " + ($wgslFailed -join "`n  "))
    }

    Write-Host "[INFO] Slang shader compilation finished ($compiled SPIR-V/WGSL artifact(s) + $wgslEmitted combined WGSL file(s))"

    # Fatal, and last so the SPIR-V summary above is still reported: an emit that
    # violates WGSL's varying rules is a toolchain regression, not a warning.
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
