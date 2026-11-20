//! A control-only native supervisor preserves fresh-worker status under a foreign SIGCHLD reaper.

use std::ffi::{c_char, c_int, CString, OsString};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::ExitStatus;
use std::time::Duration;

#[repr(C)]
struct NativeOutcome {
    worker: i32,
    status: i32,
    timed_out: i32,
    externally_reaped: i32,
}

unsafe extern "C" {
    fn ant_run_isolated_helper(
        path: *const c_char,
        arguments: *const *mut c_char,
        timeout_ms: u32,
        outcome: *mut NativeOutcome,
    ) -> c_int;
}

#[derive(Debug)]
pub struct Outcome {
    pub worker: u32,
    pub status: ExitStatus,
    pub timed_out: bool,
    pub externally_reaped: bool,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

/// The trusted nonprivileged worker executes normally; uninterruptible kernel waits still require an owning unit bound.
pub fn run(path: &Path, arguments: &[OsString], limit: Duration) -> io::Result<Outcome> {
    if !path.is_absolute() || limit.is_zero() {
        return Err(invalid(
            "helper requires an absolute path and nonzero timeout",
        ));
    }
    let timeout_ms = u32::try_from(limit.as_millis().max(1))
        .map_err(|_| invalid("helper timeout exceeds the native range"))?;
    let command =
        std::iter::once(path.as_os_str()).chain(arguments.iter().map(OsString::as_os_str));
    let values = command
        .map(|value| {
            CString::new(value.as_bytes()).map_err(|_| invalid("helper argument contains NUL"))
        })
        .collect::<io::Result<Vec<_>>>()?;
    let mut pointers = values
        .iter()
        .map(|value| value.as_ptr().cast_mut())
        .collect::<Vec<_>>();
    pointers.push(std::ptr::null_mut());
    let mut result = NativeOutcome {
        worker: 0,
        status: 0,
        timed_out: 0,
        externally_reaped: 0,
    };
    // SAFETY: the C companion borrows these NUL-terminated buffers for this call and fills the matching repr(C) layout.
    let error = unsafe {
        ant_run_isolated_helper(
            values[0].as_ptr(),
            pointers.as_ptr(),
            timeout_ms,
            &mut result,
        )
    };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    Ok(Outcome {
        worker: result.worker as u32,
        status: ExitStatus::from_raw(result.status),
        timed_out: result.timed_out != 0,
        externally_reaped: result.externally_reaped != 0,
    })
}

#[cfg(test)]
#[path = "tests/isolated_helper_tests.rs"]
mod tests;
