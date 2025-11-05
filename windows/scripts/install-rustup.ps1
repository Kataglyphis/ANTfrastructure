# scripts\install-rustup.ps1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

New-Item -Path C:\temp -ItemType Directory -Force | Out-Null
$url = 'https://win.rustup.rs/'
$out = 'C:\temp\rustup-init.exe'

$max = 5
for ($i = 0; $i -lt $max; $i++) {
    try {
        Write-Host "Versuch $($i+1) Download von $url..."
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 30
        Write-Host "Download erfolgreich."
        break
    } catch {
        Write-Host "Download attempt $($i+1) failed: $($_.Exception.Message)"
        Start-Sleep -Seconds (2 * ($i + 1))
    }
}

if (-not (Test-Path $out)) {
    Write-Host "Invoke-WebRequest schlug fehl — versuche curl als Fallback..."
    try {
        curl.exe -L -o $out $url
    } catch {
        Write-Host "curl-Fallback fehlgeschlagen: $($_.Exception.Message)"
    }
}

if (-not (Test-Path $out)) {
    Write-Error "Download fehlgeschlagen – Datei $out existiert nicht. Prüfe Netzwerk/Proxy/DNS."
    exit 1
}

Write-Host "Downloaded Größe:" (Get-Item $out).Length "bytes"
$p = Start-Process -FilePath $out -ArgumentList '-y','--default-toolchain','stable' -Wait -NoNewWindow -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    Write-Error "Rustup Installation schlug fehl mit ExitCode $($p.ExitCode)"
    exit $p.ExitCode
}
Remove-Item $out -Force
Write-Host "Rustup installation finished."
