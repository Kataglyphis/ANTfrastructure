# Run by scheduled task ansible-winget-upgrade as SYSTEM (winget cannot run over SSH).
$ErrorActionPreference = 'Continue'
$log = 'C:\Windows\Temp\winget-ansible.log'
"=== winget upgrade --all run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File $log -Encoding utf8

# The real exe inside the package dir — the WindowsApps alias refuses non-interactive sessions.
$exe = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'Microsoft.DesktopAppInstaller_*' |
    Where-Object { $_.Name -notmatch 'neutral' } |
    Sort-Object Name -Descending |
    Select-Object -First 1 |
    ForEach-Object { Join-Path $_.FullName 'winget.exe' }

if (-not (Test-Path $exe)) {
    "WINGET-NOT-FOUND" | Out-File $log -Append -Encoding utf8
    exit 2
}
"exe: $exe" | Out-File $log -Append -Encoding utf8

function Invoke-WingetLogged {
    param([string]$Header, [string[]]$WgArgs)
    $Header | Out-File $log -Append -Encoding utf8
    & $exe @WgArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-File $log -Append -Encoding utf8
}

Invoke-WingetLogged 'list available' @('upgrade', '--accept-source-agreements', '--disable-interactivity')
Invoke-WingetLogged 'upgrade --all' @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
$rc = $LASTEXITCODE
"exit code: $rc" | Out-File $log -Append -Encoding utf8
exit $rc
