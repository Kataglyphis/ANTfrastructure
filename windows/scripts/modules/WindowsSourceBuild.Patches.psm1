# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Idempotent source-patching utilities for Windows container builds.
# Extracted from WindowsSourceBuild.Common.psm1 to reduce module size.
# Every function is idempotent, guarded, and warns (never hard-fails for patch
# drift — upstream version bumps should not break the build).

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Edit-CppKeywordAlternatives {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) { return }
    $content = [System.IO.File]::ReadAllText($Path)
    $patched = $content -replace '\bor\b', '||' -replace '\band\b', '&&' -replace '\bnot\b', '!'
    if ($content -ne $patched) {
        [System.IO.File]::WriteAllText($Path, $patched)
        Write-Host "Patched keyword alternatives in: $Path"
    }
}

function Update-NinjaFile {
    param(
        [Parameter(Mandatory)]
        [string]$NinjaFile,
        [string[]]$StripPatterns = @()
    )
    if (-not (Test-Path $NinjaFile)) { return }
    $text = [System.IO.File]::ReadAllText($NinjaFile)
    $original = $text
    foreach ($pattern in $StripPatterns) {
        $text = $text -replace $pattern, ''
    }
    $text = $text -replace '  +', ' '
    if ($text -ne $original) {
        [System.IO.File]::WriteAllText($NinjaFile, $text)
        Write-Host "Patched build.ninja for clang-cl compatibility: $NinjaFile"
    }
}

function Invoke-SourcePatch {
    param(
        [Parameter(Mandatory)]
        [string]$PatchFile,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [int]$Strip = 1,
        [switch]$IgnoreWhitespace,
        [string]$Description = ''
    )
    if (-not (Test-Path $PatchFile)) { throw "Patch file not found: $PatchFile" }
    if (-not (Test-Path $SourceDir)) { throw "Source directory not found: $SourceDir" }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $PatchFile -Leaf }

    $pFlag = "-p$Strip"
    $wsFlag = @()
    if ($IgnoreWhitespace) { $wsFlag += '--ignore-whitespace' }

    $isGitRepo = $false
    if (Test-Path (Join-Path $SourceDir '.git')) {
        $isGitRepo = $true
    } else {
        $null = & git -C $SourceDir rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -eq 0) { $isGitRepo = $true }
    }

    Push-Location $SourceDir
    try {
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        Write-Host "Applying patch: $Description to $SourceDir"

        if ($isGitRepo) {
            $tool         = 'git'
            $reverseCheck = { & git apply --reverse --check $pFlag $wsFlag $PatchFile 2>&1 }
            $forwardCheck = { & git apply --check $pFlag $wsFlag $PatchFile 2>&1 }
            $applyPatch   = { & git apply $pFlag --verbose $wsFlag $PatchFile 2>&1 }
        } else {
            $patchExe = (Get-Command patch.exe -ErrorAction SilentlyContinue).Source
            if (-not $patchExe) { throw "patch.exe not found and source is not a git repo -- cannot apply $PatchFile" }
            $tool         = 'patch.exe'
            $reverseCheck = { & $patchExe $pFlag --dry-run --reverse $PatchFile 2>&1 }
            $forwardCheck = { & $patchExe $pFlag --dry-run $PatchFile 2>&1 }
            $applyPatch   = { & $patchExe $pFlag $PatchFile 2>&1 }
        }

        $null = & $reverseCheck
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  SKIP: $Description (already applied)"
            return
        }
        $null = & $forwardCheck
        if ($LASTEXITCODE -eq 0) {
            $null = & $applyPatch
            if ($LASTEXITCODE -ne 0) { throw "$tool apply failed (exit $LASTEXITCODE): $PatchFile" }
            Write-Host "  [OK] $Description applied via $tool"
            return
        }

        $msg = "ERROR: $Description -- patch does not apply cleanly to $SourceDir"
        Write-Host $msg
        Write-Host "       The upstream source may have changed. Regenerate the .patch file."
        Write-Host "--- patch file: $PatchFile ---"
        Get-Content $PatchFile -TotalCount 40 | ForEach-Object { Write-Host "       $_" }
        Write-Host '       ...'
        throw $msg
    } finally {
        $ErrorActionPreference = $oldEAP
        Pop-Location
    }
}

function Invoke-InlineRegexPatch {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Pattern,
        [string]$Replacement = '',
        [string]$Guard = '',
        [string]$WarnMessage = '',
        [switch]$Require,
        [string]$Description = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "Invoke-InlineRegexPatch: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($Guard -and ($text -notmatch $Guard)) { return $false }
    $patched = $text -replace $Pattern, $Replacement
    if ($patched -eq $text) {
        if ([string]::IsNullOrWhiteSpace($WarnMessage)) {
            $WarnMessage = "$Description : pattern not found; upstream layout may have changed. Verify $Path."
        }
        Write-Warning $WarnMessage
        return $false
    }
    [System.IO.File]::WriteAllText($Path, $patched)
    Write-Host "Patched $Description ($Path)"
    return $true
}

function Add-FileBlockOnce {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Marker,
        [Parameter(Mandatory)]
        [string]$Content,
        [switch]$Prepend,
        [string]$Encoding = '',
        [switch]$Require,
        [string]$Description = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "Add-FileBlockOnce: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    if ((Get-Content -Raw $Path) -match $Marker) { return $false }
    if ($Prepend) {
        [System.IO.File]::WriteAllText($Path, $Content + [System.IO.File]::ReadAllText($Path))
    }
    elseif ($Encoding) {
        Add-Content -LiteralPath $Path -Value $Content -Encoding $Encoding
    }
    else {
        Add-Content -LiteralPath $Path -Value $Content
    }
    Write-Host "Patched $Description"
    return $true
}

function Edit-SourceFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [scriptblock]$Transform,
        [string]$Marker = '',
        [string]$WarnMessage = '',
        [switch]$Require,
        [string]$Description = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "Edit-SourceFile: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($Marker -and ($text -match $Marker)) { return $false }
    $patched = [string](& $Transform $text)
    if ($patched -eq $text) {
        if ([string]::IsNullOrWhiteSpace($WarnMessage)) {
            $WarnMessage = "$Description : transform made no change; upstream layout may have changed. Verify $Path."
        }
        Write-Warning $WarnMessage
        return $false
    }
    [System.IO.File]::WriteAllText($Path, $patched)
    Write-Host "Patched $Description ($Path)"
    return $true
}

Export-ModuleMember -Function @(
    'Edit-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Invoke-InlineRegexPatch',
    'Add-FileBlockOnce',
    'Edit-SourceFile',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)
