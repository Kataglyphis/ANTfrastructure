$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

Write-Host 'Installing Rust via scoop (more reliable than rustup downloads)...'
scoop install main/rust 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host 'Rust installed via scoop successfully'
} else {
    Write-Host 'Scoop rust install failed, falling back to rustup...'
    rustup self update
    rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update
    rustup default stable-x86_64-pc-windows-msvc
    rustup component add rust-src clippy rustfmt llvm-tools-preview
}

where.exe cargo 2>&1 | Out-Host
where.exe rustc 2>&1 | Out-Host
cargo --version 2>&1 | Out-Host
rustc --version 2>&1 | Out-Host

foreach ($c in 'powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') {
    & where.exe $c 2>&1 | Out-Host
}
