param(
    [string]$VcpkgDir = 'C:\vcpkg'
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

Write-Host "Setting up vcpkg at $VcpkgDir..."

if (-not (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe'))) {
    Write-Host 'Cloning vcpkg...'
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    git clone --depth 1 https://github.com/microsoft/vcpkg.git $VcpkgDir 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg clone failed' }

    Push-Location $VcpkgDir
    Write-Host 'Bootstrapping vcpkg...'
    .\bootstrap-vcpkg.bat 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
    Pop-Location
    $ErrorActionPreference = $oldEap
    Write-Host 'vcpkg installed successfully'
} else {
    Write-Host 'vcpkg already installed'
}

Write-Host 'Installing dependencies via vcpkg...'
foreach ($pkg in @('zlib:x64-windows', 'protobuf:x64-windows')) {
    Write-Host "  Installing $pkg..."
    & "$VcpkgDir\vcpkg.exe" install $pkg --triplet x64-windows 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $pkg installed successfully"
    } else {
        Write-Host "  WARNING: $pkg installation may have failed"
    }
}
Write-Host 'vcpkg setup complete.'
