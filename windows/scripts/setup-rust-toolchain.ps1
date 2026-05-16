$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

rustup self update
rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update
rustup default stable-x86_64-pc-windows-msvc
rustup component add rust-src clippy rustfmt llvm-tools-preview
rustup target add x86_64-pc-windows-msvc

where.exe cargo
where.exe rustc
cargo --version
rustc --version

foreach ($c in 'gst-launch-1.0.exe','powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') {
    & where.exe $c | Out-Host
}
