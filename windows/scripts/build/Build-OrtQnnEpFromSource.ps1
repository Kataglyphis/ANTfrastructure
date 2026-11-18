# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds Qualcomm's QNN plugin EP (onnxruntime_providers_qnn.dll) from its pinned ORT fork against the chain's ORT.
.DESCRIPTION
    onnxruntime_ORT_HOME makes the fork build no ORT core of its own; see docs/windows-cross-builds.md § The QNN plugin EP.
.PARAMETER SourceDir
    The fork's source and build tree; the ORT census counts it as a chain root (Get-OrtChainSourceRoot).
#>
param(
    [string]$SourceDir = 'C:\temp\ort-qnn-ep-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$BuildType = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
Import-Module (Resolve-SourceBuildLeafModule -AssetRoot $scriptAssetRoot -Name 'WindowsNativeProvenance.Common.psm1') -DisableNameChecking
# Get-PeExportNames is not re-exported through WindowsSourceBuild.Common.
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1') -DisableNameChecking

function Get-OrtQnnEpPin {
    # Both pins or a refusal: Invoke-DownloadWithRetry treats an empty hash as no check.
    param([string]$Version = $env:ORT_QNN_EP_VERSION, [string]$Sha256 = $env:ORT_QNN_EP_SOURCE_SHA256)
    if ("$Version" -notmatch '^\d+\.\d+\.\d+$') { throw "ORT_QNN_EP_VERSION='$Version' is not a release version (stale versions.env, or the Dockerfile ARG is missing)" }
    if ("$Sha256" -notmatch '^[0-9A-Fa-f]{64}$') { throw "ORT_QNN_EP_SOURCE_SHA256='$Sha256' is not a 64-hex SHA256: refusing to fetch the QNN plugin unverified" }
    return [pscustomobject]@{
        Name = 'onnxruntime-qnn'; Version = $Version; Sha256 = $Sha256.ToLowerInvariant()
        Url  = "https://github.com/onnxruntime/onnxruntime-qnn/archive/refs/tags/v$Version.tar.gz"
    }
}

function Get-OrtQnnEpCoreVersion {
    # The ORT tag the fork's deps.txt fetches as ort_core, whose headers the plugin compiles against.
    param([Parameter(Mandatory)][string]$ForkRoot)
    $line = Select-String -LiteralPath (Join-Path $ForkRoot 'cmake\deps.txt') -Pattern '^ort_core;[^;]*/v(\d+\.\d+\.\d+)\.zip;' | Select-Object -First 1
    if (-not $line) { throw "$ForkRoot\cmake\deps.txt names no ort_core tag" }
    return $line.Matches[0].Groups[1].Value
}

function Save-OrtQnnEpCoreArchive {
    # Archive committed bytes so FetchContent still extracts and applies the fork's original patches.
    param([Parameter(Mandatory)][string]$SourceDir, [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Commit)
    $archive = Join-Path $Root "ort-core-archive/refs/tags/v$Version.zip"
    $null = New-Item -ItemType Directory -Path (Split-Path $archive -Parent) -Force
    & git -c core.autocrlf=false -c core.eol=lf -C $SourceDir archive --format=zip "--prefix=onnxruntime-$Version/" "--output=$archive" $Commit | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "QNN ort_core archive failed (exit $LASTEXITCODE)." }
    return $archive
}

function Set-OrtQnnEpCoreArchive {
    # Keep upstream patch population, using SHA256 for the newly created local transport archive.
    param([Parameter(Mandatory)][string]$ForkRoot, [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Version)
    $digest = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $changes = @(
        @{ Path = 'cmake/deps.txt'; Pattern = '(?m)^ort_core;[^\r\n]+'
            Expected = '^ort_core;https://github\.com/microsoft/onnxruntime/archive/refs/tags/v' + [regex]::Escape($Version) + '\.zip;[0-9a-f]{40}$'
            Replacement = "ort_core;$($Archive -replace '\\', '/');$digest" }
        @{ Path = 'cmake/external/onnxruntime_external_deps.cmake'; Pattern = 'URL_HASH [^\r\n]*\$\{DEP_SHA1_ort_core\}'
            Expected = '^URL_HASH SHA1=\$\{DEP_SHA1_ort_core\}$'
            Replacement = 'URL_HASH SHA256=${DEP_SHA1_ort_core}' }
    )
    foreach ($change in $changes) {
        $path = Join-Path $ForkRoot $change.Path
        $null = Edit-SourceFile -Path $path -Require -Transform {
            param($text)
            $entries = [regex]::Matches($text, $change.Pattern)
            if ($entries.Count -ne 1 -or $entries[0].Value -cnotmatch $change.Expected) { throw 'QNN ort_core dependency identity changed; refusing archive substitution.' }
            return $text.Replace($entries[0].Value, $change.Replacement)
        }.GetNewClosure()
        Assert-SourceFileContent -Path $path -Condition {
            param($text)
            $entries = [regex]::Matches($text, $change.Pattern)
            return $entries.Count -eq 1 -and $entries[0].Value -ceq $change.Replacement
        }.GetNewClosure() -FailureMessage 'QNN ort_core archive substitution did not persist.'
    }
}

function Get-OrtQnnEpChainFile {
    # The chain's core and shared-provider DLLs and import libraries, keyed by the names the fork's copy step wants.
    param([Parameter(Mandatory)][string]$OrtPrefix)
    $files = [ordered]@{}
    foreach ($name in 'onnxruntime.dll', 'onnxruntime.lib', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_shared.lib') {
        $files[$name] = Get-OrtChainPrefixFile -OrtPrefix $OrtPrefix -Name $name
    }
    return $files
}

function New-OrtQnnEpHome {
    # An onnxruntime_ORT_HOME whose lib\ is the chain's bytes; its include\ is filled after configure.
    param([Parameter(Mandatory)][string]$OrtPrefix, [Parameter(Mandatory)][string]$Path)
    Reset-SourceBuildDirectory -Path $Path
    $lib = Join-Path $Path 'lib'
    $null = New-Item -ItemType Directory -Force -Path $lib, (Join-Path $Path 'include')
    $chain = Get-OrtQnnEpChainFile -OrtPrefix $OrtPrefix
    foreach ($name in $chain.Keys) { Copy-Item -LiteralPath $chain[$name] -Destination (Join-Path $lib $name) -Force }
    return $Path
}

function Copy-OrtQnnEpHeader {
    # The fork compiles against the ORT headers it was developed for, laid out flat as a release package does.
    param([Parameter(Mandatory)][string]$OrtHome, [Parameter(Mandatory)][string]$OrtCoreSource)
    $inc = Join-Path $OrtCoreSource 'include\onnxruntime'
    if (-not (Test-Path -LiteralPath (Join-Path $inc 'core\session\onnxruntime_c_api.h') -PathType Leaf)) {
        throw "$OrtCoreSource holds no ORT public headers: the fork's configure did not populate ort_core"
    }
    $copied = 0
    foreach ($dir in 'core\session', 'core\providers\cpu', 'core\framework') {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $inc $dir) -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $OrtHome 'include') -Force
            $copied++
        }
    }
    return $copied
}

function Get-OrtQnnEpCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$QnnHome,
        [Parameter(Mandatory)][string]$QnnArchAbi,
        [Parameter(Mandatory)][string]$OrtHome,
        [Parameter(Mandatory)][string]$Python
    )
    return @(
        '-Donnxruntime_USE_QNN=ON', '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF'
        '-Donnxruntime_RUN_ONNX_TESTS=OFF', '-Donnxruntime_GENERATE_TEST_REPORTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
        "-Donnxruntime_QNN_HOME=$($QnnHome -replace '\\', '/')", "-DQNN_ARCH_ABI=$QnnArchAbi"
        "-Donnxruntime_ORT_HOME=$($OrtHome -replace '\\', '/')"
    ) + @(Get-OrtPluginEpCmakeArgs -Python $Python)
}

function Get-OrtQnnEpForeignCore {
    # The fork copies --ort_home's library into its build dir; any core DLL whose bytes are not the chain's is one it built.
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][string]$OrtPrefix)
    $chain = Get-OrtQnnEpChainFile -OrtPrefix $OrtPrefix
    $sha = @{}
    foreach ($name in $chain.Keys) { $sha[$name] = (Get-FileHash -LiteralPath $chain[$name] -Algorithm SHA256).Hash }
    $found = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $BuildDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $sha.ContainsKey($_.Name) -and $_.Extension -eq '.dll' })) {
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $sha[$file.Name]) { $found += $file.FullName }
    }
    return $found
}

function Get-OrtQnnEpModuleFinding {
    # The plugin entry points, and an import closure of the chain's ORT, QAIRT backends beside it and the OS.
    param([Parameter(Mandatory)][string]$Dll)
    $found = @(Get-OrtPluginEpExportGap -Path $Dll)
    $dir = Split-Path -Parent $Dll
    foreach ($import in @(Get-PeImportNames -Path $Dll -IncludeDelayLoad)) {
        if ($import -match '^onnxruntime' -and $import -notin 'onnxruntime.dll', 'onnxruntime_providers_shared.dll') { $found += "imports $import, which is not the chain ORT" }
        if ($import -match '^Qnn' -and -not (Test-Path -LiteralPath (Join-Path $dir $import) -PathType Leaf)) { $found += "imports $import, not staged beside it" }
    }
    return $found
}

function Copy-OrtQnnEpLicense {
    # The fork's own texts become the plugin's notices; QAIRT's ride along for the backends beside it.
    param([Parameter(Mandatory)][string]$EpDir, [Parameter(Mandatory)][string]$ForkRoot, [Parameter(Mandatory)][string]$QairtRoot)
    $forkTexts = Join-Path $EpDir 'licenses\onnxruntime-qnn'
    $qairtTexts = Join-Path $EpDir 'licenses\qairt'
    $null = New-Item -ItemType Directory -Force -Path $forkTexts, $qairtTexts
    'LICENSE', 'ThirdPartyNotices.txt' | ForEach-Object { Copy-Item -LiteralPath (Join-Path $ForkRoot $_) -Destination $forkTexts -Force }
    Get-ChildItem -LiteralPath $QairtRoot -File -Filter 'LICENSE*' -ErrorAction SilentlyContinue | Copy-Item -Destination $qairtTexts -Force
    return @('licenses\onnxruntime-qnn\LICENSE', 'licenses\onnxruntime-qnn\ThirdPartyNotices.txt')
}

function Get-OrtQnnEpBuiltDll {
    # The fork's POST_BUILD copies the DLL into its wheel tree too; the link output at the build root is the one ninja built.
    param([Parameter(Mandatory)][string]$BuildDir)
    $built = Get-Item -LiteralPath (Join-Path $BuildDir 'onnxruntime_providers_qnn.dll') -ErrorAction SilentlyContinue
    if (-not $built) { throw "QNN plugin EP: no link output onnxruntime_providers_qnn.dll at the build root $BuildDir" }
    return $built
}

function Install-OrtQnnEpArtifact {
    # One directory: the DLL, its QAIRT backends, the licence texts and a provenance manifest that proves them.
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][string]$ForkRoot, [Parameter(Mandatory)]$Sdk,
        [Parameter(Mandatory)][string]$EpDir, [Parameter(Mandatory)]$Pin)
    return Install-NativeFileStage -File (Get-OrtQnnEpBuiltDll -BuildDir $BuildDir) -Root $EpDir -Owner 'onnxruntime-qnn' -Source $Pin -Populate {
        param($dir)
        [void](Copy-QnnRuntime -Sdk $Sdk -OrtInstallDir $dir)
        Copy-OrtQnnEpLicense -EpDir $dir -ForkRoot $ForkRoot -QairtRoot $Sdk.Home
    }
}

$epDir = Join-Path $InstallDir 'lib\onnxruntime-ep-qnn'
$ortPrefix = Join-Path $InstallDir 'lib\onnxruntime-source'
$arch = Get-WindowsTargetArch
trap { Complete-SourceBuildFailure -Label 'onnxruntime-ep-qnn' -ErrorRecord $_; break }

Switch-BuildPhase '1. QAIRT SDK + pinned fork source'
$sdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256 -Arch $arch
if (-not $sdk) {
    Write-Host 'QNN plugin EP: off -- no zip in windows\qnn-sdk and no pinned Community zip (QNN_SDK_VERSION)'
    exit 0
}
$pin = Get-OrtQnnEpPin
Reset-SourceBuildDirectory -Path $SourceDir
$forkRoot = Save-VerifiedSourceArchive -Pin $pin -Archive (Join-Path $SourceDir "onnxruntime-qnn-$($pin.Version).tar.gz") -Destination (Join-Path $SourceDir 'src')
$coreVersion = Get-OrtQnnEpCoreVersion -ForkRoot $forkRoot
$coreSource = Join-Path $SourceDir 'ort-core-source'
$null = Invoke-OrtSourceClone -SourceDir $coreSource -Version $coreVersion -ExpectedCommit $env:ORT_QNN_EP_CORE_COMMIT
$coreArchive = Save-OrtQnnEpCoreArchive -SourceDir $coreSource -Root $SourceDir -Version $coreVersion -Commit $env:ORT_QNN_EP_CORE_COMMIT
Set-OrtQnnEpCoreArchive -ForkRoot $forkRoot -Archive $coreArchive -Version $coreVersion
$ortHome = New-OrtQnnEpHome -OrtPrefix $ortPrefix -Path (Join-Path $SourceDir 'ort-home')
Write-Host "QNN plugin EP v$($pin.Version) ($arch): QAIRT $($sdk.Home), chain ORT $ortPrefix, ort_core headers v$coreVersion commit=$env:ORT_QNN_EP_CORE_COMMIT"

Switch-BuildPhase '2. configure (onnxruntime_ORT_HOME: no ORT core of its own)'
$py = Initialize-ToolchainPythonEnvironment
$buildDir = Join-Path $SourceDir 'build'
$qnnArgs = Get-OrtQnnEpCmakeArgs -QnnHome $sdk.Home -QnnArchAbi (Get-QnnSdkLibDirName -Arch $arch) -OrtHome $ortHome -Python $py.Exe
$null = Invoke-CmakeConfigureLogged -LogName 'ort-qnn-ep-configure.log' -SourceDir (Join-Path $forkRoot 'cmake') -BuildDir $buildDir -InstallPrefix $epDir -BuildType $BuildType -ExtraArgs $qnnArgs
Write-Host "QNN plugin EP: $(Copy-OrtQnnEpHeader -OrtHome $ortHome -OrtCoreSource (Join-Path $buildDir '_deps\ort_core-src')) ORT header(s) from the fork's ort_core"
# The fork inherits ORT's MSVC-only switches and warnings-as-errors, which stop clang-cl as they would the ORT build.
Update-NinjaFile -NinjaFile (Join-Path $buildDir 'build.ninja') -OrtMsvcOnlyFlags

Switch-BuildPhase '3. build'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -Targets @('onnxruntime_providers_qnn') -RetryJobs 2
Write-SccacheStatsToStderr

Switch-BuildPhase '4. stage + verify'
$foreign = @(Get-OrtQnnEpForeignCore -BuildDir $buildDir -OrtPrefix $ortPrefix)
if ($foreign.Count -gt 0) { throw "the QNN plugin build holds an ONNX Runtime core the chain did not build: $($foreign -join ', ')" }
$staged = Install-OrtQnnEpArtifact -BuildDir $buildDir -ForkRoot $forkRoot -Sdk $sdk -EpDir $epDir -Pin $pin
$findings = @(Get-OrtQnnEpModuleFinding -Dll $staged)
if ($findings.Count -gt 0) { throw "QNN plugin EP check:`n  $($findings -join "`n  ")" }
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnxruntime-ep-qnn'
Complete-SourceBuild -Banner "=== QNN plugin EP build completed ($epDir) ===" -SourceDir $SourceDir
