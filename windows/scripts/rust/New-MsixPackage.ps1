# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Generic MSIX packaging script for Rust desktop applications.
  Can be upstreamed to ContainerHub.

.DESCRIPTION
  - Uses WindowsBuild.Common.psm1 for structured logging.
  - Builds a Rust binary (unless -SkipBuild is passed).
  - Copies required assets, dlls, resources, and logos.
  - Generates the AppxManifest.xml from a template.
  - Packs the MSIX.
  - Optionally signs the MSIX or generates a test certificate.
#>

# PSSA suppressions, justified: this script signs DEV/test MSIX packages with a
# throwaway self-signed certificate. The password travels as a plain build
# parameter by design (CI secret injection); converting the public parameter
# surface to SecureString would break existing callers for no real secrecy
# gain (the PFX and its password live in the same build workspace).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'dev/test signing cert; see comment above')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'dev/test signing cert; see comment above')]
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Binary,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$Publisher,
    [Parameter(Mandatory)][string]$PublisherDisplayName,
    [Parameter(Mandatory)][string]$DisplayName,
    [string]$Description = "",
    [string]$Version = "0.1.0.0",
    [string]$Features = "",
    [string]$OutputDirectory = "dist\msix",
    [string]$CargoTargetDir = "target-msix",
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$LogoPath = "images\logo.png",
    [string]$ManifestTemplatePath = "packaging\msix\AppxManifest.template.xml",
    [string]$ResourcesDir = "resources",
    [switch]$CreateTestCertificate,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

# Import ContainerHub build framework (relative to this script's location in ContainerHub).
# WindowsScripts.Shared and WindowsMsix.Common are requested explicitly because
# Initialize-CiEnvironment defaults to WindowsBuild.Common only -- which is why this
# script used to carry its own copies of Assert-Command, ConvertTo-NormalizedVersion
# and an SDK-tool lookup.
. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @(
    'WindowsBuild.Common',
    'WindowsScripts.Shared',
    'WindowsMsix.Common'
)

# Initialize Build Context
$logDir = Join-Path $Workspace "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$Context = New-BuildContext -Workspace $Workspace -LogDir $logDir -StopOnError
Open-BuildLog -Context $Context

# Assert-Command and ConvertTo-NormalizedVersion now come from
# WindowsScripts.Shared, and the SDK-tool lookup from WindowsMsix.Common's
# Resolve-WindowsSdkToolPath. The local copies were behaviourally identical for
# the first two; the third was strictly worse -- it only globbed the two
# hardcoded "Windows Kits\10\bin" roots, while the shared one honours
# WindowsSdkVerBinPath / WindowsSdkBinPath / WindowsSDKVersion first and accepts
# an explicit override path. Same not-found contract either way: $null.

function New-PasswordSecureString([string]$Password) {
    if ([string]::IsNullOrWhiteSpace($Password)) { throw "A non-empty -CertificatePassword is required" }
    return ConvertTo-SecureString -String $Password -AsPlainText -Force
}

# NOTE: Scripting.FileSystemObject COM object may not be available in minimal Windows containers
function Import-CertificateAndSign {
    param(
        [Parameter(Mandatory)] [string]$CertificatePath,
        [Parameter(Mandatory)] [string]$CertificatePassword,
        [Parameter(Mandatory)] [string]$PackageFile,
        [Parameter(Mandatory)] [string]$SigntoolExe,
        [Parameter(Mandatory)] [pscustomobject]$Context,
        [switch]$CreatedAsTestCert
    )

    $thumbprint = $null
    try {
        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $x509.Import($CertificatePath, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)

        try {
            if (Test-Path $CertificatePath) {
                $fi = Get-Item $CertificatePath
                Write-BuildLog -Context $Context -Message "PFX exists: $CertificatePath (Length=$($fi.Length) LastWrite=$($fi.LastWriteTime))"
                try { $hash = (Get-FileHash -Path $CertificatePath -Algorithm SHA256).Hash; Write-BuildLog -Context $Context -Message "PFX SHA256: $hash" } catch { Write-BuildLog -Context $Context -Message "Get-FileHash failed: $($_.Exception.Message)" }
            }
            Write-BuildLog -Context $Context -Message "Certificate Thumbprint (imported): $($x509.Thumbprint)"
            Write-BuildLog -Context $Context -Message "HasPrivateKey: $($x509.HasPrivateKey)"
        } catch { Write-BuildLog -Context $Context -Message "Certificate debug logging failed: $($_.Exception.Message)" }

        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','CurrentUser')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($x509)
        $store.Close()

        $thumbprint = $x509.Thumbprint
        $thumb = $thumbprint
        Write-BuildLog -Context $Context -Message "Imported certificate thumbprint: $thumb"

        # Give the certificate store a moment to settle before signtool reads it
        # (previously a decorated 6x300ms sleep loop).
        Start-Sleep -Milliseconds 1800

        try {
            $storeOut = & certutil -store My $thumb 2>&1
            $storeOut = @($storeOut)
            Write-BuildLog -Context $Context -Message ("DEBUG: certutil -store output:`n$($storeOut -join "`n")")
        } catch {
            Write-BuildLogWarning -Context $Context -Message "certutil -store failed: $($_.Exception.Message)"
        }

        $signArgs = @("sign", "/fd", "SHA256", "/sha1", $thumb, "/v", $PackageFile)
        Write-BuildLog -Context $Context -Message "DEBUG: signtool command: $SigntoolExe $($signArgs -join ' ')"
        $sigOut = & $SigntoolExe @signArgs 2>&1
        $exit = $LASTEXITCODE
        Write-BuildLog -Context $Context -Message "DEBUG: signtool exit code: $exit"
        if ($sigOut) { $sigOut = @($sigOut); Write-BuildLog -Context $Context -Message ("DEBUG: signtool output:`n$($sigOut -join "`n")") }
        # A non-zero signtool exit must not pass silently: throw so the catch
        # below attempts the direct-invocation fallback (and the fallback's own
        # failure propagates to the critical build step).
        if ($exit -ne 0) {
            throw "signtool sign (by thumbprint) failed with exit code $exit"
        }
    } catch {
        Write-BuildLogWarning -Context $Context -Message "Import/sign by thumbprint failed, falling back to direct signtool invocation. Details: $($_.Exception.Message)"
        $signArgs = @("sign", "/fd", "SHA256", "/f", $CertificatePath, "/p", $CertificatePassword, "/v", $PackageFile)
        # Display copy only: never log the PFX password. The element after '/p'
        # is masked; $signArgs itself stays intact for execution.
        $displayArgs = @($signArgs)
        $pIndex = [Array]::IndexOf($displayArgs, '/p')
        if ($pIndex -ge 0 -and ($pIndex + 1) -lt $displayArgs.Count) { $displayArgs[$pIndex + 1] = '<redacted>' }
        Write-BuildLog -Context $Context -Message "DEBUG: signtool command: $SigntoolExe $($displayArgs -join ' ')"
        $sigOut = & $SigntoolExe @signArgs 2>&1
        $exit = $LASTEXITCODE
        Write-BuildLog -Context $Context -Message "DEBUG: signtool exit code: $exit"
        if ($sigOut) { Write-BuildLog -Context $Context -Message ("DEBUG: signtool output:`n$($sigOut -join "`n")") }
        # Fallback failed too: fail the signing step. This propagates through
        # the critical "Sign MSIX" build step (Context has -StopOnError) into
        # the script's exit 1 path instead of shipping an unsigned package.
        if ($exit -ne 0) {
            throw "signtool sign (fallback, direct PFX) failed with exit code $exit"
        }
    } finally {
        try {
            if ($thumbprint) {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','CurrentUser')
                $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $toRemove = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint }
                foreach ($c in $toRemove) { $store.Remove($c) }
                $store.Close()
            }
        } catch {
            Write-BuildLogWarning -Context $Context -Message "Failed to remove imported certificate: $($_.Exception.Message)"
        }
    }
}

try {
    Write-BuildLog -Context $Context -Message "=== MSIX Packaging Environment ==="
    Write-BuildLog -Context $Context -Message "Workspace: $Workspace"
    Write-BuildLog -Context $Context -Message "Binary: $Binary"
    Write-BuildLog -Context $Context -Message "PackageName: $PackageName"
    
    $Workspace = (Resolve-Path $Workspace).Path
    $Version = ConvertTo-NormalizedVersion $Version
    
    $resolvedCargoTargetDir = Join-Path $Workspace $CargoTargetDir
    $env:CARGO_TARGET_DIR = $resolvedCargoTargetDir
    $env:CARGO_INCREMENTAL = "0"
    
    $makeappxExe = ""
    $signtoolExe = ""
    $exePath = ""
    $outDir = ""
    $stagingRoot = ""
    $packageFile = ""

    Invoke-BuildStep -Context $Context -StepName "Verify Dependencies" -Critical -Script {
        Assert-Command -Name "cargo" -InstallHint "Install Rust toolchain via rustup"
        
        # Resolve-WindowsSdkToolPath joins the name onto candidate dirs verbatim,
        # so it wants the ".exe" that the old local helper used to append.
        $script:makeappxExe = Resolve-WindowsSdkToolPath -ToolName "makeappx.exe"
        if ([string]::IsNullOrWhiteSpace($makeappxExe)) { throw "makeappx not found. Install Windows SDK" }

        $script:signtoolExe = Resolve-WindowsSdkToolPath -ToolName "signtool.exe"
        if ([string]::IsNullOrWhiteSpace($signtoolExe)) { throw "signtool not found. Install Windows SDK" }
        
        Write-BuildLog -Context $Context -Message "Using makeappx: $makeappxExe"
        Write-BuildLog -Context $Context -Message "Using signtool: $signtoolExe"
    }

    if (-not $SkipBuild) {
        Invoke-BuildStep -Context $Context -StepName "Build Release Binary" -Critical -Script {
            Set-Location $Workspace
            $cargoParams = @("build", "--release", "--bin", $Binary, "--jobs", "1")
            if (-not [string]::IsNullOrWhiteSpace($Features)) {
                $cargoParams += @("--features", $Features)
            }
            Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $cargoParams
        }
    }

    Invoke-BuildStep -Context $Context -StepName "Stage Files" -Critical -Script {
        $releaseDir = Join-Path $resolvedCargoTargetDir "release"
        $script:exePath = Join-Path $releaseDir "$Binary.exe"
        if (-not (Test-Path $exePath)) { throw "Binary not found: $exePath" }

        $script:outDir = Join-Path $Workspace $OutputDirectory
        $script:stagingRoot = Join-Path $outDir "staging"
        $assetsDir = Join-Path $stagingRoot "Assets"

        if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null

        Write-BuildLog -Context $Context -Message "Copying binary and DLLs..."
        Copy-Item $exePath -Destination $stagingRoot -Force
        Get-ChildItem -Path $releaseDir -Filter "*.dll" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName -Destination $stagingRoot -Force }

        $resourcesSource = Join-Path $Workspace $ResourcesDir
        if (Test-Path $resourcesSource) {
            Write-BuildLog -Context $Context -Message "Copying resources from $resourcesSource"
            Copy-Item $resourcesSource -Destination (Join-Path $stagingRoot "resources") -Recurse -Force
        }

        $resolvedLogoPath = Join-Path $Workspace $LogoPath
        if (-not (Test-Path $resolvedLogoPath)) { throw "Logo file not found at $resolvedLogoPath" }

        Write-BuildLog -Context $Context -Message "Copying logos..."
        Copy-Item $resolvedLogoPath -Destination (Join-Path $assetsDir "StoreLogo.png") -Force
        Copy-Item $resolvedLogoPath -Destination (Join-Path $assetsDir "Square44x44Logo.png") -Force
        Copy-Item $resolvedLogoPath -Destination (Join-Path $assetsDir "Square150x150Logo.png") -Force
        Copy-Item $resolvedLogoPath -Destination (Join-Path $assetsDir "Wide310x150Logo.png") -Force

        $resolvedManifestPath = Join-Path $Workspace $ManifestTemplatePath
        if (-not (Test-Path $resolvedManifestPath)) { throw "Manifest template not found: $resolvedManifestPath" }

        Write-BuildLog -Context $Context -Message "Generating AppxManifest.xml..."
        $manifestContent = Get-Content $resolvedManifestPath -Raw
        $manifestContent = $manifestContent.Replace("__PACKAGE_NAME__", $PackageName)
        $manifestContent = $manifestContent.Replace("__PUBLISHER__", $Publisher)
        $manifestContent = $manifestContent.Replace("__VERSION__", $Version)
        $manifestContent = $manifestContent.Replace("__DISPLAY_NAME__", $DisplayName)
        $manifestContent = $manifestContent.Replace("__PUBLISHER_DISPLAY_NAME__", $PublisherDisplayName)
        $manifestContent = $manifestContent.Replace("__DESCRIPTION__", $Description)
        $manifestContent = $manifestContent.Replace("__EXECUTABLE__", "$Binary.exe")
        Set-Content -Path (Join-Path $stagingRoot "AppxManifest.xml") -Value $manifestContent -Encoding utf8
    }

    Invoke-BuildStep -Context $Context -StepName "Pack MSIX" -Critical -Script {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $script:packageFile = Join-Path $outDir ("{0}_{1}_x64.msix" -f $PackageName, $Version)
        if (Test-Path $packageFile) { Remove-Item $packageFile -Force }

        # makeappx pack /d <staging> /p <output> /o
        Invoke-BuildExternal -Context $Context -File $makeappxExe -Parameters @("pack", "/d", $stagingRoot, "/p", $packageFile, "/o")
    }

    Invoke-BuildStep -Context $Context -StepName "Sign MSIX" -Critical -Script {
        if ($CreateTestCertificate) {
            if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
                $CertificatePath = Join-Path $outDir "$PackageName.testcert.pfx"
            }
            if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
                throw "-CreateTestCertificate requires -CertificatePassword"
            }

            Write-BuildLog -Context $Context -Message "Creating self-signed test certificate..."
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher -CertStoreLocation "Cert:\CurrentUser\My"
            $securePassword = New-PasswordSecureString -Password $CertificatePassword
            Export-PfxCertificate -Cert $cert -FilePath $CertificatePath -Password $securePassword | Out-Null

            Write-BuildLog -Context $Context -Message "Signing package with generated test certificate..."
            Import-CertificateAndSign -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword -PackageFile $packageFile -SigntoolExe $signtoolExe -Context $Context -CreatedAsTestCert
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
            if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
                throw "-CertificatePassword is required when -CertificatePath is provided"
            }

            Write-BuildLog -Context $Context -Message "Signing package with provided certificate..."
            Import-CertificateAndSign -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword -PackageFile $packageFile -SigntoolExe $signtoolExe -Context $Context
        }
        else {
            Write-BuildLogWarning -Context $Context -Message "MSIX created but not signed. Installation will typically fail until it is signed."
        }
    }

    Write-BuildLogSuccess -Context $Context -Message "MSIX package ready: $packageFile"
    Write-BuildSummary -Context $Context
    exit 0
} catch {
    Write-BuildLogError -Context $Context -Message "Packaging failed: $($_.Exception.Message)"
    Write-BuildSummary -Context $Context
    exit 1
} finally {
    Close-BuildLog -Context $Context
}

