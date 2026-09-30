Set-StrictMode -Version Latest
#requires -Version 7.0


# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# Without Get-OrDefault the catch below would degrade CommandNotFound to a warning and ship unsigned.
if (-not (Get-Module -Name 'WindowsConfig.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsConfig.Common.psm1')
}

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

# Kept so the tests can mock Test-Administrator inside this module.
function Test-Administrator {
  return (Test-Elevated)
}

function Invoke-MsixSign {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'dev/test signing cert')]
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$MsixOutPath,
    # Test seam called instead of Invoke-BuildExternal.
    [scriptblock]$InvokerScriptBlock
  )

  try {
    $signtoolPath = Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath $null
    if ([string]::IsNullOrWhiteSpace($signtoolPath)) {
      Write-BuildLogWarning -Context $Context -Message 'signtool.exe not found. Skipping MSIX signing.'
      return
    }

    $pfxFiles = Get-ChildItem -Path $WorkspacePath -Filter '*.pfx' -File -ErrorAction SilentlyContinue
    $pfxFiles = @($pfxFiles)
    if (($null -ne $pfxFiles) -and ($pfxFiles.Count -gt 0)) {
      $pfx = $pfxFiles[0].FullName
      Write-BuildLog -Context $Context -Message "Found PFX for signing: $($pfxFiles[0].Name)"

      # MSIX_CERT_PASSWORD is the CI fallback.
      $pfxPassword = Get-OrDefault $env:MSIX_PFX_PASSWORD $env:MSIX_CERT_PASSWORD
      $timestampUrl = Get-OrDefault $env:MSIX_TIMESTAMP_URL 'http://timestamp.digicert.com'

      $sigArgs = @('sign', '/fd', 'SHA256', '/f', $pfx)
      if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
        $sigArgs += @('/p', $pfxPassword)
      } else {
        Write-BuildLogWarning -Context $Context -Message 'MSIX_PFX_PASSWORD not set. Attempting to sign without password (PFX may be unprotected).'
      }
      $sigArgs += @('/tr', $timestampUrl, '/td', 'SHA256', $MsixOutPath)

      Write-BuildLog -Context $Context -Message "Signing MSIX: $MsixOutPath"
      if ($InvokerScriptBlock) {
        & $InvokerScriptBlock -Context $Context -File $signtoolPath -Parameters $sigArgs | Out-Null
      } else {
        Invoke-BuildExternal -Context $Context -File $signtoolPath -Parameters $sigArgs | Out-Null
      }

      # Warn, not throw: the package is already signed, and unelevated consumer dev loops must still get it.
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

      Write-BuildLog -Context $Context -Message "Verifying MSIX signature: $MsixOutPath"
      if ($InvokerScriptBlock) {
        & $InvokerScriptBlock -Context $Context -File $signtoolPath -Parameters @('verify', '/pa', '/v', $MsixOutPath) | Out-Null
      } else {
        Invoke-BuildExternal -Context $Context -File $signtoolPath -Parameters @('verify', '/pa', '/v', $MsixOutPath) | Out-Null
      }
      Write-BuildLog -Context $Context -Message 'MSIX signing/verification completed.'
    } else {
      Write-BuildLogWarning -Context $Context -Message "No .pfx found in $WorkspacePath; MSIX will not be signed."
    }
  } catch [System.Management.Automation.CommandNotFoundException] {
    # A missing command is a broken import graph, never a warning that ships unsigned.
    throw
  } catch {
    # Best-effort: builds without signing material still produce a usable unsigned package.
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
