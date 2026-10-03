# One-time summy-server OpenSSH setup: DefaultShell + ACL fix. Run via SSH.
$ErrorActionPreference = 'Stop'

# Default shell for OpenSSH sessions -> PowerShell (cmd breaks ansible module serialization).
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
$shell = if (Test-Path $pwsh7) { $pwsh7 } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell
Write-Output "DefaultShell = $shell"

# Correct ACL on the administrators_authorized_keys (SIDs, locale-independent).
$file = "$env:ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $file) {
    icacls $file /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'
} else {
    Write-Output "WARN: $file not found"
}

# Sanity: sshd_config must reference the administrators file.
$cfg = Get-Content "$env:ProgramData\ssh\sshd_config" -Raw
if ($cfg -notmatch 'administrators_authorized_keys') {
    Write-Output 'WARN: administrators_authorized_keys not configured in sshd_config'
}
Write-Output 'DONE'
