// Copyright (c) 2026 Kataglyphis
// SPDX-License-Identifier: MIT

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

/// Compiles an ICO for one Cargo binary on Windows MSVC targets.
pub fn add_windows_icon(binary: &str, icon: &Path) {
    println!("cargo:rerun-if-env-changed=LLVM_RC");
    println!("cargo:rerun-if-env-changed=RC");
    println!("cargo:rerun-if-changed={}", file!());
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc") {
        panic!("Windows icon resources require a Windows MSVC target");
    }
    if binary.is_empty()
        || !binary
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        panic!("invalid Cargo binary name: {binary}");
    }
    let icon = icon
        .canonicalize()
        .unwrap_or_else(|error| panic!("cannot open icon {}: {error}", icon.display()));
    let text = icon
        .to_str()
        .expect("the icon path must be UTF-8")
        .replace('\\', "/");
    if text.contains(['"', '\r', '\n']) {
        panic!("the icon path cannot contain quotes or newlines");
    }
    let bytes = fs::read(&icon)
        .unwrap_or_else(|error| panic!("cannot read icon {}: {error}", icon.display()));
    if bytes.len() < 6 || bytes[..4] != [0, 0, 1, 0] || bytes[4..6] == [0, 0] {
        panic!("not a valid ICO header: {}", icon.display());
    }
    println!("cargo:rerun-if-changed={}", icon.display());
    let dir = env::var_os("OUT_DIR").expect("Cargo did not set OUT_DIR");
    let dir = Path::new(&dir);
    let source = dir.join(format!("{binary}-icon.rc"));
    let resource = dir.join(format!("{binary}-icon.res"));
    if resource.exists() {
        fs::remove_file(&resource)
            .unwrap_or_else(|error| panic!("cannot remove stale {}: {error}", resource.display()));
    }
    fs::write(&source, format!("1 ICON \"{text}\"\n"))
        .unwrap_or_else(|error| panic!("cannot write {}: {error}", source.display()));
    let compiler = env::var_os("LLVM_RC")
        .or_else(|| env::var_os("RC"))
        .unwrap_or_else(|| "llvm-rc".into());
    let status = Command::new(&compiler)
        .arg("/fo")
        .arg(&resource)
        .arg(&source)
        .status()
        .unwrap_or_else(|error| panic!("cannot start {:?}: {error}", compiler));
    if !status.success() || fs::metadata(&resource).map_or(true, |file| file.len() == 0) {
        panic!("icon resource compilation failed: {status}");
    }
    println!("cargo:rustc-link-arg-bin={binary}={}", resource.display());
}
