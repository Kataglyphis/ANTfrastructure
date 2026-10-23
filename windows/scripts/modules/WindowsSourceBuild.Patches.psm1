#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Idempotent source patching that warns on upstream drift unless the caller asks for -Fatal.

Set-StrictMode -Version Latest

# No -Force: reloading a nested dependency removes the caller's exported commands.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -ErrorAction Stop

function Edit-CppKeywordAlternatives {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (Edit-SourceFile -Path $Path -Quiet -Transform {
            param($content)
            $content -replace '\bor\b', '||' -replace '\band\b', '&&' -replace '\bnot\b', '!'
        }) {
        Write-Host "Patched keyword alternatives in: $Path"
    }
}

function Update-NinjaFile {
    param(
        [Parameter(Mandatory)]
        [string]$NinjaFile,
        [string[]]$StripPatterns = @()
    )
    if (Edit-SourceFile -Path $NinjaFile -Quiet -Transform {
            param($original)
            # Collapsing whitespace outside changed lines would corrupt paths embedded in build.ninja.
            $lines = $original -split '(?<=\n)'
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                $stripped = $line
                foreach ($pattern in $StripPatterns) { $stripped = $stripped -replace $pattern, '' }
                if ($stripped -ne $line) { $lines[$i] = $stripped -replace '  +', ' ' }
            }
            -join $lines
        }) {
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
            # -i is load-bearing: without it patch.exe reads an empty patch from stdin and exits 0.
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
            # Capture the --verbose output: on failure the hunk detail is the diagnosis, not the exit code.
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
    # The .patch, then a drift-tolerant fallback in the caller's scope; -Fatal throws on a double miss.
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

# Verify the written file, since a successful replacement call alone cannot prove the required fix landed.
function Assert-SourceFileContent {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$FailureMessage)
    $text = [System.IO.File]::ReadAllText($Path)
    $verdict = @(& $Condition $text)
    if ($verdict.Count -ne 1 -or $verdict[0] -isnot [bool] -or -not $verdict[0]) { throw $FailureMessage }
}

function Edit-SourceRegexText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Map)
    foreach ($edit in $Map) { $Text = [regex]::Replace($Text, $edit.Pattern, $edit.Replacement) }
    return $Text
}

function Add-SourceRegexGuard {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Pattern,
        [Parameter(Mandatory)][string]$Condition,
        [string]$Comment = '',
        [string]$Indent = ''
    )
    $prefix = "#if $Condition$(if ($Comment) { "  // $Comment" })`n$Indent"
    $wrap = { param($match) $prefix + $match.Value + "`n#endif" }.GetNewClosure()
    $map = @(foreach ($expression in $Pattern) { @{ Pattern = $expression; Replacement = [Text.RegularExpressions.MatchEvaluator]$wrap } })
    Edit-SourceRegexText -Text $Text -Map $map
}

function Read-SourcePatchInput {
    param([string]$Path, [string]$Description, [string]$CallerName, [switch]$Require, [string]$Marker = '', [string]$Guard = '')
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "${CallerName}: file not found: $Path" }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    $text = [System.IO.File]::ReadAllText($Path)
    if (($Marker -and ($text -match $Marker)) -or ($Guard -and ($text -notmatch $Guard))) { return $null }
    [pscustomobject]@{ Description = $Description; Text = $text }
}

# Regex and callback patches share write/no-change verdicts without sharing their transformation semantics.
function Save-SourcePatchText {
    param([string]$Path, [string]$Original, [string]$Patched, [string]$Description,
        [string]$WarnMessage, [string]$NoChangeReason, [string]$AssertGone = '', [switch]$Quiet)
    if ($Patched -eq $Original) {
        if ($AssertGone -and ($Original -match $AssertGone)) { throw "$Description : pattern not found and '$AssertGone' still present in $Path -- upstream layout changed, refusing to continue" }
        if ([string]::IsNullOrWhiteSpace($WarnMessage)) {
            $WarnMessage = "$Description : $NoChangeReason; upstream layout may have changed. Verify $Path."
        }
        if (-not $Quiet) { Write-Warning $WarnMessage }
        return $false
    }
    [System.IO.File]::WriteAllText($Path, $Patched)
    if ($AssertGone -and ($Patched -match $AssertGone)) { throw "$Description : '$AssertGone' still present after patching $Path -- the replacement did not remove it" }
    if (-not $Quiet) { Write-Host "Patched $Description ($Path)" }
    return $true
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
        # A match means already applied: return $true, touch nothing.
        [string]$SkipIfMatch = '',
        # Throws when the file still matches this after writing, or when the pattern was never found.
        [string]$AssertGone = '',
        [switch]$Quiet,
        [switch]$IfPresent
    )
    if ($IfPresent -and -not (Test-Path $Path)) { return $false }
    $patchInput = Read-SourcePatchInput -Path $Path -Description $Description -CallerName 'Invoke-InlineRegexPatch' -Require:($Require -or [bool]$AssertGone)
    if ($null -eq $patchInput) { return $false }
    $Description = $patchInput.Description
    $text = $patchInput.Text
    if ($SkipIfMatch -and ($text -match $SkipIfMatch)) {
        if (-not $Quiet) { Write-Host "$Description already applied ($Path)" }
        return $true
    }
    if ($Guard -and ($text -notmatch $Guard)) {
        if ($AssertGone -and ($text -match $AssertGone)) { throw "$Description : guard not found but the pattern it protects is still present in $Path -- upstream layout changed, refusing to continue" }
        return $false
    }
    $patched = $text -replace $Pattern, $Replacement
    Save-SourcePatchText -Path $Path -Original $text -Patched $patched -Description $Description `
        -WarnMessage $WarnMessage -NoChangeReason 'pattern not found' -AssertGone $AssertGone -Quiet:$Quiet
}

<#
.SYNOPSIS
    DirectML EP clang-cl fix: moves AbstractOperatorDesc members out of line, after OperatorField is complete.
.DESCRIPTION
    clang-cl (llvm #57700) rejects instantiating them against the incomplete type. The regex fallback behind
    the .patch: idempotent via the "[clang-cl DML fix]" marker, a no-op when the anchors no longer match.
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

function Edit-SourceStaticLibraryReferences {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePath,
        [string]$NamePattern = '[a-zA-Z0-9_-]+',
        [string]$NamePrefix = '',
        [switch]$RequireLeadingSlash,
        [scriptblock]$Description = { param($relative) "$relative : GNU static library names -> MSVC" }
    )
    $slash = if ($RequireLeadingSlash) { '/' } else { '' }
    $pattern = $slash + 'lib' + [regex]::Escape($NamePrefix) + '(' + $NamePattern + ')\.a'
    $replacement = $slash + $NamePrefix.Replace('$', '$$') + '$1.lib'
    Invoke-SourceFilePatchSet -File $RelativePath -Patch {
        param($relative)
        Invoke-InlineRegexPatch -Path (Join-Path $SourceRoot $relative) -Pattern $pattern -Replacement $replacement -Guard $pattern `
            -Description (& $Description $relative)
    }
}

function Invoke-SourceFilePatchSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$File,
        [Parameter(Mandatory)][scriptblock]$Patch,
        [scriptblock]$OnChanged
    )
    $changed = 0
    foreach ($item in $File) {
        if (& $Patch $item ($changed + 1)) {
            $changed++
            if ($OnChanged) { & $OnChanged $item $changed | Out-Null }
        }
    }
    return $changed
}

function Invoke-VerifiedSourceFilePatch {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][scriptblock]$Patch, [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$FailureMessage, [System.Collections.IDictionary]$Message = @{},
        [scriptblock]$Log = { param($text) Write-Host $text })
    $status = 'Missing'
    if (Test-Path $Path) {
        if ([IO.File]::ReadAllText($Path) -match $Marker) { $status = 'Already' }
        else {
            & $Patch $Path | Out-Null
            Assert-SourceFileContent -Path $Path -Condition $Condition -FailureMessage $FailureMessage
            $status = 'Patched'
        }
    }
    if ($Message.Contains($status)) {
        $text = $Message[$status]
        if ($text -is [scriptblock]) { $text = & $text }
        & $Log ([string]$text) | Out-Null
    }
    return $status
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
    $patchInput = Read-SourcePatchInput -Path $Path -Description $Description -CallerName 'Add-FileBlockOnce' -Require:$Require -Marker $Marker
    if ($null -eq $patchInput) { return $false }
    $Description = $patchInput.Description
    if ($Prepend) {
        [System.IO.File]::WriteAllText($Path, $Content + $patchInput.Text)
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
        [string]$Description = '',
        [switch]$Quiet,
        [string]$Guard = ''
    )
    $patchInput = Read-SourcePatchInput -Path $Path -Description $Description -CallerName 'Edit-SourceFile' -Require:$Require -Marker $Marker -Guard $Guard
    if ($null -eq $patchInput) { return $false }
    Save-SourcePatchText -Path $Path -Original $patchInput.Text -Patched ([string](& $Transform $patchInput.Text)) -Description $patchInput.Description `
        -WarnMessage $WarnMessage -NoChangeReason 'transform made no change' -Quiet:$Quiet
}

Export-ModuleMember -Function @(
    'Invoke-OnnxDmlClangClPatch',
    'Edit-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Invoke-SourcePatchWithFallback',
    'Invoke-InlineRegexPatch',
    'Invoke-SourceFilePatchSet',
    'Edit-SourceStaticLibraryReferences',
    'Assert-SourceFileContent',
    'Invoke-VerifiedSourceFilePatch',
    'Add-FileBlockOnce',
    'Edit-SourceFile',
    'Add-SourceRegexGuard',
    'Edit-SourceRegexText',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

