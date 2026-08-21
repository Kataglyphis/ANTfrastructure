Set-StrictMode -Version Latest
#requires -Version 7.0


# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
# No -Force when already loaded: a nested force-reimport moves the module's
# exports out of the global session state on Windows PowerShell 5.1.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# Get-OrDefault (used by Invoke-MsixSign for the env-var fallbacks) lives in
# WindowsConfig.Common. Without this import, Invoke-MsixSign hit
# CommandNotFound inside its try block, the blanket catch degraded that to a
# warning, and the package shipped silently UNSIGNED.
if (-not (Get-Module -Name 'WindowsConfig.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsConfig.Common.psm1')
}

# Invoke-BuildExternal / Write-BuildLog* come from the sibling
# WindowsBuild.Common module; without this import a standalone consumer hits
# CommandNotFound at runtime. Guarded, WITHOUT -Force (repo-wide nested-import
# rule, 2026-08-04): a forced nested re-import would pull a caller's top-level
# import out of the global session state.
if (-not (Get-Module -Name 'WindowsBuild.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

function Test-Administrator {
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Invoke-MsixSign {
  # PSSA suppression, justified: dev/test MSIX signing with a throwaway
  # self-signed cert; the password arrives as a plain build parameter by
  # design (same rationale as New-MsixPackage.ps1).
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'dev/test signing cert')]
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$MsixOutPath,
    # Optional invoker scriptblock for testability. If provided, it will be called instead of Invoke-BuildExternal.
    [scriptblock]$InvokerScriptBlock
  )

  try {
    $signtoolPath = Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath $null
    if ([string]::IsNullOrWhiteSpace($signtoolPath)) {
      Write-BuildLogWarning -Context $Context -Message 'signtool.exe not found. Skipping MSIX signing.'
      return
    }

    # Look for an explicit .pfx in the workspace root (non-recursive).
    $pfxFiles = Get-ChildItem -Path $WorkspacePath -Filter '*.pfx' -File -ErrorAction SilentlyContinue
    $pfxFiles = @($pfxFiles)
    if (($null -ne $pfxFiles) -and ($pfxFiles.Count -gt 0)) {
      $pfx = $pfxFiles[0].FullName
      Write-BuildLog -Context $Context -Message "Found PFX for signing: $($pfxFiles[0].Name)"

      # Prefer MSIX_PFX_PASSWORD, fall back to MSIX_CERT_PASSWORD for CI compatibility
      $pfxPassword = Get-OrDefault $env:MSIX_PFX_PASSWORD $env:MSIX_CERT_PASSWORD
      $timestampUrl = Get-OrDefault $env:MSIX_TIMESTAMP_URL 'http://timestamp.digicert.com'

      $sigArgs = @('sign', '/fd', 'SHA256', '/f', $pfx)
      if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
        $sigArgs += @('/p', $pfxPassword)
      } else {
        Write-BuildLogWarning -Context $Context -Message 'MSIX_PFX_PASSWORD not set. Attempting to sign without password (PFX may be unprotected).'
      }
      # Use RFC3161 timestamping with SHA256
      $sigArgs += @('/tr', $timestampUrl, '/td', 'SHA256', $MsixOutPath)

      Write-BuildLog -Context $Context -Message "Signing MSIX: $MsixOutPath"
      if ($InvokerScriptBlock) {
        & $InvokerScriptBlock -Context $Context -File $signtoolPath -Parameters $sigArgs | Out-Null
      } else {
        Invoke-BuildExternal -Context $Context -File $signtoolPath -Parameters $sigArgs | Out-Null
      }

      # Import the signing certificate into the LocalMachine trust store so
      # subsequent signtool verify calls succeed when using a self-signed PFX.
      # DELIBERATE WARN-NOT-THROW (#145, documented 2026-08-21): the package
      # IS signed above regardless — only the trust-store import for the
      # local `signtool verify` needs elevation. Consumer dev loops
      # (BeschleunigerBallett/NativeInferencePlugin Build-Windows) run
      # unelevated and must still produce the signed MSIX; a throw here
      # would break them for a verification nicety. The degraded state is
      # named in the warning, so this is not the Slang-class silent skip.
      try {
        if (-not (Test-Administrator)) {
          Write-BuildLogWarning -Context $Context -Message 'Not running as Administrator; skipping PFX import into LocalMachine certificate store. signtool verify may fail.'
        } else {
          Write-BuildLog -Context $Context -Message 'Importing PFX into Cert:\\LocalMachine\\Root to trust the signing chain for verification.'
          if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
            $securePassword = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
            $imported = Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\\LocalMachine\\Root' -Password $securePassword -ErrorAction Stop
          } else {
            $imported = Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\\LocalMachine\\Root' -ErrorAction Stop
          }

          if ($null -ne $imported) {
            $thumbprints = @()
            if ($imported -is [System.Array]) { $thumbprints = $imported | ForEach-Object { $_.Thumbprint } }
            else { $thumbprints = @($imported.Thumbprint) }
            Write-BuildLog -Context $Context -Message "Imported certificate(s) into LocalMachine\\Root: $([string]::Join(', ', $thumbprints))"
          }
        }
      } catch {
        Write-BuildLogWarning -Context $Context -Message ("PFX import failed: $($_.Exception.Message)")
      }

      # Verify signature
      Write-BuildLog -Context $Context -Message "Verifying MSIX signature: $MsixOutPath"
      if ($InvokerScriptBlock) {
        & $InvokerScriptBlock -Context $Context -File $signtoolPath -Parameters @('verify', '/pa', '/v', $MsixOutPath) | Out-Null
      } else {
        Invoke-BuildExternal -Context $Context -File $signtoolPath -Parameters @('verify', '/pa', '/v', $MsixOutPath) | Out-Null
      }
      Write-BuildLog -Context $Context -Message 'MSIX signing/verification completed.'
    } else {
      Write-BuildLogWarning -Context $Context -Message 'No .pfx found at repository root; MSIX will not be signed.'
    }
  } catch [System.Management.Automation.CommandNotFoundException] {
    # A missing function/command is a BUG (broken import graph), not a
    # signing-environment condition - never swallow it into a warning, or the
    # package ships silently unsigned.
    throw
  } catch {
    # Genuine signing failures stay best-effort by contract (matching the
    # signtool-not-found and no-.pfx-found warning paths above): dev/CI builds
    # without signing material still produce a usable, unsigned package.
    Write-BuildLogWarning -Context $Context -Message ("MSIX signing step failed: $($_.Exception.Message)")
  }
}

# Approved-verb wrapper for the signing flow. Keeps Invoke-MsixSign for compatibility.
function Start-MsixSigning {
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$MsixOutPath,
    [scriptblock]$InvokerScriptBlock
  )

  return Invoke-MsixSign -Context $Context -WorkspacePath $WorkspacePath -MsixOutPath $MsixOutPath -InvokerScriptBlock $InvokerScriptBlock
}

Export-ModuleMember -Function @(
  'Invoke-MsixSign',
  'Start-MsixSigning',
  'Test-Administrator'
)
