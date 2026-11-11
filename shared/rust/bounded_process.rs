//! Fresh Linux children isolate runtime work; an uninterruptible kernel request still needs an owning unit bound.

use std::ffi::c_int;
use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};

const CLOSE_RANGE_CLOEXEC: c_int = 4;
const ECHILD: c_int = 10;
type CloseRange = unsafe extern "C" fn(u32, u32, c_int) -> c_int;

unsafe extern "C" {
    fn close_range(first: u32, last: u32, flags: c_int) -> c_int;
}

#[derive(Debug)]
pub struct Outcome {
    pub child: u32,
    pub status: ExitStatus,
    pub timed_out: bool,
}

fn terminate_and_reap(child: &mut Child) -> io::Result<ExitStatus> {
    let killed = child.kill();
    let waited = child.wait();
    killed?;
    waited
}

fn run_with_close(mut command: Command, limit: Duration, close: CloseRange) -> io::Result<Outcome> {
    let deadline = Instant::now()
        .checked_add(limit)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "child deadline overflow"))?;
    // SAFETY: this callback only marks descriptors CLOEXEC through libc and reads errno; it allocates no runtime state.
    unsafe {
        command.pre_exec(move || {
            if close(3, u32::MAX, CLOSE_RANGE_CLOEXEC) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
    let mut child = command.spawn()?;
    let pid = child.id();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return Ok(Outcome {
                    child: pid,
                    status,
                    timed_out: false,
                })
            }
            Ok(None) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                // ECHILD means ownership was lost to another reaper; its PID must never be signalled again.
                if error.raw_os_error() != Some(ECHILD) {
                    terminate_and_reap(&mut child)?;
                }
                return Err(error);
            }
        }
        if Instant::now() >= deadline {
            let status = terminate_and_reap(&mut child)?;
            return Ok(Outcome {
                child: pid,
                status,
                timed_out: true,
            });
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The caller owns SIGCHLD handling and must not reap this function's child from another handler.
pub fn run(command: Command, limit: Duration) -> io::Result<Outcome> {
    run_with_close(command, limit, close_range)
}

#[cfg(test)]
#[path = "tests/bounded_process_tests.rs"]
mod tests;
