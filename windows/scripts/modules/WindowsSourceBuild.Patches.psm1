#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Idempotent source-patching utilities for Windows container builds.
# Extracted from WindowsSourceBuild.Common.psm1 to reduce module size.
# Every function is idempotent, guarded, and warns (never hard-fails for patch
# drift — upstream version bumps should not break the build).

Set-StrictMode -Version Latest

# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

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
    $original = [System.IO.File]::ReadAllText($NinjaFile)
    # Line-scoped: strip patterns + collapse the double-space residue ONLY on
    # lines a pattern actually changed. The old global '  +' -> ' ' collapse
    # rewrote every multi-space run in build.ninja (paths with consecutive
    # spaces, aligned comments) — latent breakage far beyond the stripped flags.
    $lines = $original -split '(?<=\n)'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $stripped = $line
        foreach ($pattern in $StripPatterns) {
            $stripped = $stripped -replace $pattern, ''
        }
        if ($stripped -ne $line) {
            $lines[$i] = $stripped -replace '  +', ' '
        }
    }
    $text = -join $lines
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
            # -i is LOAD-BEARING. A bare path is the file to PATCH, not the
            # patch; without -i, patch.exe reads an empty patch from stdin,
            # changes nothing and exits 0 -- so the reverse-check below reads as
            # "already applied" and EVERY patch is silently skipped. Measured
            # 2026-08-27 on the LLVM tarball, which is the first non-git source
            # tree to use this branch (OpenCV and contrib are git clones and
            # take the git apply path above, which is why this never showed).
            $tool         = 'patch.exe'
            $reverseCheck = { & $patchExe $pFlag --dry-run --reverse -i $PatchFile 2>&1 }
            $forwardCheck = { & $patchExe $pFlag --dry-run -i $PatchFile 2>&1 }
            $applyPatch   = { & $patchExe $pFlag -i $PatchFile 2>&1 }
        }

        $null = & $reverseCheck
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  SKIP: $Description (already applied)"
            return
        }
        $null = & $forwardCheck
        if ($LASTEXITCODE -eq 0) {
            # Capture the --verbose output it explicitly requests: on failure
            # the hunk-level detail is the diagnosis, not the exit code.
            $applyOut = @(& $applyPatch)
            if ($LASTEXITCODE -ne 0) {
                $tail = ($applyOut | Select-Object -Last 10) -join [Environment]::NewLine
                throw "$tool apply failed (exit $LASTEXITCODE): $PatchFile`n$tail"
            }
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

function Invoke-SourcePatchWithFallback {
    # The two-rung apply ladder every version-sensitive patch uses (backlog #7):
    # rung 1 is the reviewable .patch (skips cleanly when already applied),
    # rung 2 the EOL/context-tolerant inline fallback for upstream drift.
    # The Fallback scriptblock executes in the CALLER's scope (PS scriptblocks
    # carry their creation SessionState), so it can use the caller's variables.
    # -Fatal (backlog #19): the fallback must RETURN $true, or the ladder
    # throws - for patches whose silent absence produces a broken build hours
    # later (e.g. 006: a rotted patch would re-enable the sccache nvcc crash
    # the day the CUDA launcher is retried). Without -Fatal a double miss
    # stays a warning, preserving the never-hard-fail-on-drift default above.
    param(
        [Parameter(Mandatory)]
        [string]$PatchFile,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [scriptblock]$Fallback,
        [string]$FallbackNote = 'falling back to inline patcher',
        [switch]$Fatal
    )
    try {
        Invoke-SourcePatch -PatchFile $PatchFile -SourceDir $SourceDir -IgnoreWhitespace
        return $true
    } catch {
        Write-Host ("{0} did not apply cleanly -- {1}" -f (Split-Path $PatchFile -Leaf), $FallbackNote)
    }
    $applied = & $Fallback
    $ok = @($applied) -contains $true
    if (-not $ok -and $Fatal) {
        throw ("{0}: BOTH the .patch and the inline fallback failed to apply -- refusing to continue (load-bearing patch; a silent miss breaks the build hours later)." -f (Split-Path $PatchFile -Leaf))
    }
    return $ok
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
        [string]$Description = '',
        # Idempotency (#131): when the file already matches this regex the patch
        # is considered applied -- return $true, touch nothing, say so. Replaces
        # the hand-rolled `elseif ((Get-Content ...) -match <new>)` at call sites.
        [string]$SkipIfMatch = '',
        # Load-bearing patches (#131): after writing, the file must NOT match
        # this regex any more -- otherwise throw with -Description. Also throws
        # when the pattern was never found and the file still matches it (the
        # "did not apply cleanly, upstream layout changed" case every consumer
        # used to re-read the file to detect).
        [string]$AssertGone = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require -or $AssertGone) { throw "Invoke-InlineRegexPatch: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($SkipIfMatch -and ($text -match $SkipIfMatch)) {
        Write-Host "$Description already applied ($Path)"
        return $true
    }
    if ($Guard -and ($text -notmatch $Guard)) {
        if ($AssertGone -and ($text -match $AssertGone)) { throw "$Description : guard not found but the pattern it protects is still present in $Path -- upstream layout changed, refusing to continue" }
        return $false
    }
    $patched = $text -replace $Pattern, $Replacement
    if ($patched -eq $text) {
        if ($AssertGone -and ($text -match $AssertGone)) { throw "$Description : pattern not found and '$AssertGone' still present in $Path -- upstream layout changed, refusing to continue" }
        if ([string]::IsNullOrWhiteSpace($WarnMessage)) {
            $WarnMessage = "$Description : pattern not found; upstream layout may have changed. Verify $Path."
        }
        Write-Warning $WarnMessage
        return $false
    }
    [System.IO.File]::WriteAllText($Path, $patched)
    if ($AssertGone -and ($patched -match $AssertGone)) { throw "$Description : '$AssertGone' still present after patching $Path -- the replacement did not remove it" }
    Write-Host "Patched $Description ($Path)"
    return $true
}

<#
.SYNOPSIS
    ONNX Runtime DirectML EP clang-cl fix: moves AbstractOperatorDesc's special
    members, GetTensors<>() and the four tensor accessors out of line into
    GeneratedSchemaTypes.h, after OperatorField is complete.
.DESCRIPTION
    OperatorField is an incomplete type at the point where MSVC (which defers
    special-member instantiation to end-of-TU) is fine and clang-cl (correctly,
    llvm #57700) is not. This is the regex fallback behind the checked-in
    .patch file; it lived inside build-onnx-from-source.ps1 until #131
    (2026-08-25) -- 80 lines of embedded C++ in a build script. Idempotent
    ("[clang-cl DML fix]" marker); silently a no-op when the upstream layout
    no longer matches all three anchors (the caller's patch-file path is the
    primary route and reports its own outcome).
#>
function Invoke-OnnxDmlClangClPatch {
    param([Parameter(Mandatory)][string]$SourceDir)

    $dmlHelpers  = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\External\DirectMLHelpers"
    $dmlAbstract = Join-Path $dmlHelpers 'AbstractOperatorDesc.h'
    $dmlTypes    = Join-Path $dmlHelpers 'GeneratedSchemaTypes.h'
    if ((Test-Path $dmlAbstract) -and (Test-Path $dmlTypes)) {
        $abs = [System.IO.File]::ReadAllText($dmlAbstract)
        if ($abs -notmatch '\[clang-cl DML fix\]') {
            $ctorRx = 'AbstractOperatorDesc\(\) = default;\r?\n\s*AbstractOperatorDesc\(const DML_OPERATOR_SCHEMA\* schema, std::vector<OperatorField>&& fields\)\r?\n\s*: schema\(schema\)\r?\n\s*, fields\(std::move\(fields\)\)\r?\n\s*\{\}'
            $accessorRx = '(?s)(std::vector<[^\r\n]+?> Get(?:Input|Output)Tensors\(\)(?: const)?)\r?\n\s*\{\r?\n\s*return GetTensors<[^\r\n]+?>\(\);\r?\n\s*\}'
            $getTensorsRx = '(?s)template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>\r?\n\s*std::vector<TensorType\*> GetTensors\(\) const\r?\n\s*\{.*?return tensors;\r?\n\s*\}'
            $ctorHit = [regex]::IsMatch($abs, $ctorRx)
            $accHit  = ([regex]::Matches($abs, $accessorRx)).Count
            $gtHit   = ([regex]::Matches($abs, $getTensorsRx)).Count
            if ($ctorHit -and $accHit -eq 4 -and $gtHit -eq 1) {
                $ctorDecls = @'
AbstractOperatorDesc();
    AbstractOperatorDesc(const DML_OPERATOR_SCHEMA* schema, std::vector<OperatorField>&& fields);
    AbstractOperatorDesc(const AbstractOperatorDesc&);
    AbstractOperatorDesc(AbstractOperatorDesc&&) noexcept;
    AbstractOperatorDesc& operator=(const AbstractOperatorDesc&);
    AbstractOperatorDesc& operator=(AbstractOperatorDesc&&) noexcept;
    ~AbstractOperatorDesc();
'@
                $gtDecl = @'
template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>
    std::vector<TensorType*> GetTensors() const;
'@
                $abs = [regex]::Replace($abs, $ctorRx, $ctorDecls)
                $abs = [regex]::Replace($abs, $accessorRx, '$1;')
                $abs = [regex]::Replace($abs, $getTensorsRx, $gtDecl)
                $abs = $abs -replace '(class OperatorField;)', "`$1`r`n// [clang-cl DML fix] special members + GetTensors + accessors moved out-of-line to GeneratedSchemaTypes.h"
                [System.IO.File]::WriteAllText($dmlAbstract, $abs)
                $outOfLine = @'

// [clang-cl DML fix] Out-of-line AbstractOperatorDesc members. Defined here, AFTER OperatorField is
// complete, so the std::vector<OperatorField> special members (dtor/move), GetTensors<>() and the 4
// tensor accessors instantiate against a complete type. Left inline they instantiate via
// optional<AbstractOperatorDesc> while OperatorField is still forward-declared, which clang-cl rejects
// (MSVC defers method/special-member instantiation to end-of-TU, where the type is complete).
inline AbstractOperatorDesc::AbstractOperatorDesc() = default;
inline AbstractOperatorDesc::AbstractOperatorDesc(const DML_OPERATOR_SCHEMA* schema, std::vector<OperatorField>&& fields)
    : schema(schema), fields(std::move(fields)) {}
inline AbstractOperatorDesc::AbstractOperatorDesc(const AbstractOperatorDesc&) = default;
inline AbstractOperatorDesc::AbstractOperatorDesc(AbstractOperatorDesc&&) noexcept = default;
inline AbstractOperatorDesc& AbstractOperatorDesc::operator=(const AbstractOperatorDesc&) = default;
inline AbstractOperatorDesc& AbstractOperatorDesc::operator=(AbstractOperatorDesc&&) noexcept = default;
inline AbstractOperatorDesc::~AbstractOperatorDesc() = default;
template <typename TensorType, DML_SCHEMA_FIELD_KIND Kind>
std::vector<TensorType*> AbstractOperatorDesc::GetTensors() const
{
    std::vector<TensorType*> tensors;
    for (auto& field : fields)
    {
        const DML_SCHEMA_FIELD* fieldSchema = field.GetSchema();
        if (fieldSchema->Kind != Kind)
        {
            continue;
        }

        if (fieldSchema->Type == DML_SCHEMA_FIELD_TYPE_TENSOR_DESC)
        {
            auto& tensor = field.AsTensorDesc();
            tensors.push_back(tensor ? const_cast<TensorType*>(&*tensor) : nullptr);
        }
        else if (fieldSchema->Type == DML_SCHEMA_FIELD_TYPE_TENSOR_DESC_ARRAY)
        {
            auto& tensorArray = field.AsTensorDescArray();
            if (tensorArray)
            {
                for (auto& tensor : *tensorArray)
                {
                    tensors.push_back(const_cast<TensorType*>(&tensor));
                }
            }
        }
    }
    return tensors;
}
inline std::vector<DmlBufferTensorDesc*> AbstractOperatorDesc::GetInputTensors()
{
    return GetTensors<DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_INPUT_TENSOR>();
}
inline std::vector<const DmlBufferTensorDesc*> AbstractOperatorDesc::GetInputTensors() const
{
    return GetTensors<const DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_INPUT_TENSOR>();
}
inline std::vector<DmlBufferTensorDesc*> AbstractOperatorDesc::GetOutputTensors()
{
    return GetTensors<DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_OUTPUT_TENSOR>();
}
inline std::vector<const DmlBufferTensorDesc*> AbstractOperatorDesc::GetOutputTensors() const
{
    return GetTensors<const DmlBufferTensorDesc, DML_SCHEMA_FIELD_KIND_OUTPUT_TENSOR>();
}
'@
                [System.IO.File]::AppendAllText($dmlTypes, $outOfLine)
                Write-Host 'Applied [clang-cl DML fix]: out-of-lined AbstractOperatorDesc special members + GetTensors + 4 tensor accessors'
            } else {
                Write-Warning "[clang-cl DML fix] anchors not found (ctor=$ctorHit accessors=$accHit gettensors=$gtHit) -- DirectML may fail under clang-cl. Verify $dmlAbstract."
            }
        }
    } else {
        Write-Warning 'DirectMLHelpers headers not found -- skipping the clang-cl DML fix (USE_DML build may fail).'
    }

    $dmlAuthorImpl = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\MLOperatorAuthorImpl.cpp"
    [void](Invoke-InlineRegexPatch -Path $dmlAuthorImpl `
            -Pattern '(initializer)\.##Z\(\)' -Replacement '$1.Z()' `
            -Description 'clang-cl DML fix #2 (dropped spurious `.##Z` token-paste in MLOperatorAuthorImpl.cpp CASE_PROTO)' `
            -WarnMessage '[clang-cl DML fix #2] `.##Z` token-paste not found in MLOperatorAuthorImpl.cpp (already fixed upstream?) -- skipping.')

    $dmlOps = "$SourceDir\onnxruntime\core\providers\dml\DmlExecutionProvider\src\Operators"
    foreach ($opHeader in @('DmlDFT.h', 'DmlGridSample.h')) {
        [void](Invoke-InlineRegexPatch -Path (Join-Path $dmlOps $opHeader) `
                -Pattern 'template <typename TConstants, uint32_t TSize>' `
                -Replacement 'template <typename TConstants, size_t TSize>' `
                -Description "clang-cl DML fix #3 (widened Dispatch<TSize> to size_t in $opHeader)" `
                -WarnMessage "[clang-cl DML fix #3] uint32_t TSize decl not found in $opHeader (already fixed upstream?) -- skipping.")
    }
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
    'Invoke-OnnxDmlClangClPatch',
    'Edit-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Invoke-SourcePatchWithFallback',
    'Invoke-InlineRegexPatch',
    'Add-FileBlockOnce',
    'Edit-SourceFile',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

