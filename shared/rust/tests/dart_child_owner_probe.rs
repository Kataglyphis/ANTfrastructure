//! The real VM fixture checks worker status and fake-HIP sanitizer teardown, not a real GPU or model.

#[path = "../bounded_process.rs"]
mod bounded_process;
#[path = "../isolated_helper.rs"]
mod isolated_helper;
#[path = "../loaded_module.rs"]
mod loaded_module;

use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

static FOREIGN_REAPS: AtomicI32 = AtomicI32::new(0);

fn error_code(error: io::Error) -> i32 {
    error.raw_os_error().unwrap_or(999)
}

fn checked_status(worker: u32, timed_out: bool, success: bool) -> i32 {
    if worker > 0 && !timed_out && success {
        0
    } else {
        1000
    }
}

#[no_mangle]
pub extern "C" fn ant_probe_native_child() -> i32 {
    isolated_helper::run(Path::new("/bin/true"), &[], Duration::from_secs(5))
        .map(|result| {
            if result.externally_reaped {
                FOREIGN_REAPS.fetch_add(1, Ordering::Relaxed);
            }
            checked_status(result.worker, result.timed_out, result.status.success())
        })
        .unwrap_or_else(error_code)
}

#[no_mangle]
pub extern "C" fn ant_probe_original_child() -> i32 {
    bounded_process::run(
        std::process::Command::new("/bin/true"),
        Duration::from_secs(5),
    )
    .map(|result| checked_status(result.child, result.timed_out, result.status.success()))
    .unwrap_or_else(error_code)
}

#[no_mangle]
pub extern "C" fn ant_probe_native_statuses() -> i32 {
    let cases = [
        ("exit 42", Some(42), None, false),
        ("kill -TERM $$", None, Some(15), false),
        ("exec /bin/sleep 10", None, Some(9), true),
    ];
    for (source, code, signal, timeout) in cases {
        let result = isolated_helper::run(
            Path::new("/bin/sh"),
            &["-c".into(), source.into()],
            Duration::from_millis(100),
        );
        let Ok(result) = result else {
            return 1001;
        };
        if result.worker == 0
            || result.status.code() != code
            || result.status.signal() != signal
            || result.timed_out != timeout
        {
            return 1002;
        }
    }
    let error = isolated_helper::run(
        Path::new("/no-such-worker-for-dart"),
        &[],
        Duration::from_secs(5),
    );
    if !matches!(error, Err(error) if error.raw_os_error() == Some(2)) {
        return 1003;
    }
    0
}

#[no_mangle]
pub extern "C" fn ant_probe_foreign_reaps() -> i32 {
    FOREIGN_REAPS.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn ant_probe_native_hip() -> i32 {
    let Some(worker) = std::env::var_os("ANT_TEST_HIP_WORKER") else {
        return 1010;
    };
    let Some(runtime) = std::env::var_os("ANT_TEST_HIP_RUNTIME") else {
        return 1011;
    };
    let leak_device = std::env::var("ANT_TEST_HIP_LEAK_DEVICE").unwrap_or_else(|_| "46".into());
    if !matches!(leak_device.as_str(), "46" | "47") {
        return 1015;
    }
    let cases = [
        ("0", 0),
        ("42", 15),
        ("43", 14),
        ("44", 16),
        ("45", 17),
        (leak_device.as_str(), 86),
        ("-1", 13),
        ("bad", 2),
    ];
    for (device, expected) in cases {
        let result = isolated_helper::run(
            Path::new(&worker),
            &[runtime.clone(), device.into()],
            Duration::from_secs(5),
        );
        let Ok(result) = result else {
            return 1012;
        };
        if result.worker == 0 || result.timed_out || result.status.code() != Some(expected) {
            return 1013;
        }
    }
    let missing = Path::new(&runtime).with_file_name("absent-hip-runtime.so");
    let result = isolated_helper::run(
        Path::new(&worker),
        &[missing.into_os_string(), "0".into()],
        Duration::from_secs(5),
    );
    match result {
        Ok(result)
            if result.worker > 0 && !result.timed_out && result.status.code() == Some(10) =>
        {
            0
        }
        _ => 1014,
    }
}

#[no_mangle]
pub extern "C" fn ant_probe_module_owner() -> i32 {
    let Some(expected) = std::env::var_os("ANT_TEST_MODULE_PATH") else {
        return 20;
    };
    let Ok(expected) = std::fs::canonicalize(expected) else {
        return 21;
    };
    match loaded_module::path_for_address(
        ant_probe_module_owner as *const () as *const std::ffi::c_void,
    ) {
        Ok(actual) if actual == expected => 0,
        Ok(_) => 22,
        Err(_) => 23,
    }
}
