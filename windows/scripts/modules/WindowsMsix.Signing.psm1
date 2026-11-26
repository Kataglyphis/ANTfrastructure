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
  param([pscustomobject]$Context, [string]$File, [string[]]$Parameters, [scriptblock]$Invoker, [string[]]$Redact = @())
  if ($Invoker) { & $Invoker -Context $Context -File $File -Parameters $Parameters | Out-Null }
  else { Invoke-BuildExternal -Context $Context -File $File -Parameters $Parameters -RedactParameterValues $Redact | Out-Null }
}

# The first set variable wins, so MSIX_CERT_PASSWORD stays the CI fallback behind MSIX_PFX_PASSWORD.
function Get-AuthenticodePassword {
  param([string[]]$Variables)
  foreach ($name in $Variables) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrEmpty($value)) { return $value }
  }
  return ''
}

function Read-PfxCertificate {
  <#
    .SYNOPSIS
      The thumbprint and private-key presence of a .pfx, read without touching any certificate store.
  #>
  param([Parameter(Mandatory)] [string]$PfxPath, [securestring]$SigningPassword)
  $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
  $pfx = if ($SigningPassword) { [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $SigningPassword, $flags) }
  else { [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, [string]::Empty, $flags) }
  try { return [pscustomobject]@{ Thumbprint = $pfx.Thumbprint; HasPrivateKey = $pfx.HasPrivateKey } } finally { $pfx.Dispose() }
}

function Assert-AuthenticodeSigner {
  <#
    .SYNOPSIS
      Fail unless -Path carries a signature by the certificate in -PfxPath; an untrusted test root still passes.
  #>
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$PfxPath,
    [securestring]$SigningPassword,
    # Read when -SigningPassword is absent, as Invoke-AuthenticodeSign reads it.
    [string[]]$SecretEnvironmentName = @('MSIX_PFX_PASSWORD', 'MSIX_CERT_PASSWORD'),
    # Test seam: returns an object with Status and SignerCertificate for a path.
    [scriptblock]$SignatureReader = { param($p) Get-AuthenticodeSignature -FilePath $p }
  )
  if (-not $SigningPassword) {
    $secret = Get-AuthenticodePassword -Variables $SecretEnvironmentName
    if ($secret) { $SigningPassword = ConvertTo-MsixSigningPassword -Password $secret }
  }
  $expected = (Read-PfxCertificate -PfxPath $PfxPath -SigningPassword $SigningPassword).Thumbprint
  $signature = & $SignatureReader $Path
  $signer = if ($signature) { $signature.SignerCertificate } else { $null }
  if (-not $signer -or $signer.Thumbprint -ne $expected) {
    throw "Authenticode signer of $Path is '$(if ($signer) { $signer.Thumbprint } else { 'none' })', not the signing certificate $expected"
  }
  # A test certificate's root is untrusted, which Windows reports as UnknownError; a broken hash never passes.
  if ([string]$signature.Status -notin @('Valid', 'UnknownError', 'NotTrusted')) {
    throw "Authenticode signature of $Path is $($signature.Status): $($signature.StatusMessage)"
  }
}

function Invoke-AuthenticodeSign {
  <#
    .SYNOPSIS
      Sign one file with signtool and verify it; returns $true when signed.
    .DESCRIPTION
      A signtool or verification failure always throws. A missing signtool or .pfx warns and returns $false,
      unless -Require makes it an error too. The password comes from the first set -SecretEnvironmentName and is
      redacted in the build log.
    .PARAMETER Verify
      Trusted runs signtool verify /pa, which needs a trusted root; Signer checks the signer's thumbprint, for test certificates.
  #>
  param(
    [Parameter(Mandatory)] [pscustomobject]$Context,
    [Parameter(Mandatory)] [string]$Path,
    [AllowEmptyString()] [string]$PfxPath,
    [string[]]$SecretEnvironmentName = @('MSIX_PFX_PASSWORD', 'MSIX_CERT_PASSWORD'),
    [AllowEmptyString()] [string]$TimestampUrl = (Get-OrDefault $env:MSIX_TIMESTAMP_URL 'http://timestamp.digicert.com'),
    [ValidateSet('Trusted', 'Signer')] [string]$Verify = 'Trusted',
    [switch]$Require,
    # Runs after signing and before verification, such as a trust-store import.
    [scriptblock]$BeforeVerify,
    [scriptblock]$SignatureReader,
    # Test seam called instead of Invoke-BuildExternal.
    [scriptblock]$InvokerScriptBlock
  )
  # The .pfx first: without one there is nothing to sign, so the SDK need not be probed.
  $signtool = ''
  $missing = if ([string]::IsNullOrWhiteSpace($PfxPath) -or -not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { "no signing .pfx at '$PfxPath'" }
  else {
    $signtool = Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath $null
    if ([string]::IsNullOrWhiteSpace($signtool)) { 'signtool.exe not found' }
  }
  if ($missing) {
    if ($Require) { throw "Cannot sign ${Path}: $missing" }
    Write-BuildLogWarning -Context $Context -Message "Skipping signing of ${Path}: $missing"
    return $false
  }

  $secret = Get-AuthenticodePassword -Variables $SecretEnvironmentName
  $signingPassword = if ($secret) { ConvertTo-MsixSigningPassword -Password $secret } else { $null }
  $sigArgs = @('sign', '/fd', 'SHA256', '/f', $PfxPath)
  if ($secret) { $sigArgs += @('/p', $secret) }
  else { Write-BuildLogWarning -Context $Context -Message "None of $($SecretEnvironmentName -join ', ') is set; signing with an unprotected PFX." }
  if ($TimestampUrl) { $sigArgs += @('/tr', $TimestampUrl, '/td', 'SHA256') }
  $sigArgs += $Path

  Write-BuildLog -Context $Context -Message "Signing: $Path"
  Invoke-MsixSigningCommand -Context $Context -File $signtool -Parameters $sigArgs -Invoker $InvokerScriptBlock -Redact @($secret)
  if ($BeforeVerify) { & $BeforeVerify $PfxPath $signingPassword }
  if ($Verify -eq 'Trusted') {
    Invoke-MsixSigningCommand -Context $Context -File $signtool -Parameters @('verify', '/pa', '/v', $Path) -Invoker $InvokerScriptBlock
  } else {
    $assertArgs = @{ Path = $Path; PfxPath = $PfxPath; SigningPassword = $signingPassword }
    if ($SignatureReader) { $assertArgs.SignatureReader = $SignatureReader }
    Assert-AuthenticodeSigner @assertArgs
  }
  Write-BuildLog -Context $Context -Message "Signed and verified: $Path"
  return $true
}

function Import-MsixSigningCertificate {
  param([pscustomobject]$Context, [string]$Pfx, [bool]$IsAdministrator, [securestring]$SigningPassword)
  if (-not $IsAdministrator) {
    Write-BuildLogWarning -Context $Context -Message 'Not running as Administrator; skipping PFX import into LocalMachine certificate store. signtool verify may fail.'
    return
  }
  Write-BuildLog -Context $Context -Message 'Importing PFX into Cert:\\LocalMachine\\Root to trust the signing chain for verification.'
  if ($SigningPassword) {
    $imported = Import-PfxCertificate -FilePath $Pfx -CertStoreLocation 'Cert:\\LocalMachine\\Root' -Password $SigningPassword -ErrorAction Stop
  } else {
    $imported = Import-PfxCertificate -FilePath $Pfx -CertStoreLocation 'Cert:\\LocalMachine\\Root' -ErrorAction Stop
  }
  if ($null -ne $imported) {
    $thumbprints = if ($imported -is [System.Array]) { @($imported | ForEach-Object { $_.Thumbprint }) }
    else { @($imported.Thumbprint) }
    Write-BuildLog -Context $Context -Message "Imported certificate(s) into LocalMachine\\Root: $([string]::Join(', ', $thumbprints))"
  }
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
    # The first .pfx in the workspace signs, as before; none leaves the package unsigned.
    $pfx = [string]((@(Get-ChildItem -Path $WorkspacePath -Filter '*.pfx' -File -ErrorAction SilentlyContinue))[0]?.FullName)
    # The package is already signed, so trust-store import stays advisory in developer builds.
    $importTrust = {
      param($pfxPath, [securestring]$securePassword)
      try {
        $isAdministrator = Test-Administrator
        $importPassword = if ($isAdministrator) { $securePassword } else { $null }
        Import-MsixSigningCertificate -Context $Context -Pfx $pfxPath -IsAdministrator $isAdministrator -SigningPassword $importPassword
      } catch {
        Write-BuildLogWarning -Context $Context -Message ("PFX import failed: $($_.Exception.Message)")
      }
    }
    [void](Invoke-AuthenticodeSign -Context $Context -Path $MsixOutPath -PfxPath $pfx -BeforeVerify $importTrust -InvokerScriptBlock $InvokerScriptBlock)
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
  'Invoke-AuthenticodeSign',
  'Assert-AuthenticodeSigner',
  'Read-PfxCertificate',
  'Start-MsixSigning',
  'Test-Administrator',
  'New-TestSigningCertificate'
)
