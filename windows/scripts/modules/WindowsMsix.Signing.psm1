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

function Invoke-MsixSigningCommand {
  param([pscustomobject]$Context, [string]$File, [string[]]$Parameters, [scriptblock]$Invoker)
  if ($Invoker) { & $Invoker -Context $Context -File $File -Parameters $Parameters | Out-Null }
  else { Invoke-BuildExternal -Context $Context -File $File -Parameters $Parameters | Out-Null }
}

function Invoke-MsixSign {
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
      Invoke-MsixSigningCommand -Context $Context -File $signtoolPath -Parameters $sigArgs -Invoker $InvokerScriptBlock

      # Warn, not throw: the package is already signed, and unelevated consumer dev loops must still get it.
      try {
        if (-not (Test-Administrator)) {
          Write-BuildLogWarning -Context $Context -Message 'Not running as Administrator; skipping PFX import into LocalMachine certificate store. signtool verify may fail.'
        } else {
          Write-BuildLog -Context $Context -Message 'Importing PFX into Cert:\\LocalMachine\\Root to trust the signing chain for verification.'
          if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
            $securePassword = ConvertTo-MsixSigningPassword -Password $pfxPassword
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
      Invoke-MsixSigningCommand -Context $Context -File $signtoolPath -Parameters @('verify', '/pa', '/v', $MsixOutPath) -Invoker $InvokerScriptBlock
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

function New-TestSigningCertificate {
  <#
    .SYNOPSIS
      A throwaway code-signing certificate for -Subject, made in memory and written as a .pfx (and -CerPath's .cer); returns its thumbprint.
    .DESCRIPTION
      No certificate store is touched, so a run leaves nothing behind. Without -Password the .pfx is unprotected: delete it once signed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Subject,
    [Parameter(Mandatory)][string]$PfxPath,
    [string]$CerPath = '',
    [securestring]$Password,
    [int]$ValidYears = 1
  )

  $x509 = 'Security.Cryptography.X509Certificates'
  $rsa = [Security.Cryptography.RSA]::Create(2048)
  try {
    $request = New-Object "$x509.CertificateRequest" $Subject, $rsa, ([Security.Cryptography.HashAlgorithmName]::SHA256), ([Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add((New-Object "$x509.X509BasicConstraintsExtension" $false, $false, 0, $true))
    $request.CertificateExtensions.Add((New-Object "$x509.X509KeyUsageExtension" ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature), $true))
    $codeSigning = [Security.Cryptography.OidCollection]::new()
    $null = $codeSigning.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add((New-Object "$x509.X509EnhancedKeyUsageExtension" $codeSigning, $false))
    $now = [DateTimeOffset]::UtcNow
    $cert = $request.CreateSelfSigned($now.AddDays(-1), $now.AddYears($ValidYears))
    $pfx = if ($Password) { $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password) }
    else { $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx) }
    [IO.File]::WriteAllBytes($PfxPath, $pfx)
    if ($CerPath) { [IO.File]::WriteAllBytes($CerPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)) }
    return $cert.Thumbprint
  } finally {
    $rsa.Dispose()
  }
}

Export-ModuleMember -Function @(
  'Invoke-MsixSign',
  'Start-MsixSigning',
  'Test-Administrator',
  'New-TestSigningCertificate'
)
