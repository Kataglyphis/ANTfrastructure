//! Real workers prove transport and cleanup, not HIP, package placement or a kernel-blocked request.

use super::*;
use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::process::ExitStatusExt;
use std::time::Instant;

unsafe extern "C" {
    fn kill(pid: c_int, signal: c_int) -> c_int;
    fn fcntl(fd: c_int, command: c_int, ...) -> c_int;
}

fn shell(source: &str, limit: Duration) -> io::Result<Outcome> {
    run(Path::new("/bin/sh"), &["-c".into(), source.into()], limit)
}

fn assert_gone(worker: u32) {
    // SAFETY: signal zero only observes existence, so a reused PID causes a failed test rather than a signal to another owner.
    assert_eq!(unsafe { kill(worker as c_int, 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(3));
}

#[test]
fn successful_worker_is_gone_before_return() {
    let outcome = run(Path::new("/bin/true"), &[], Duration::from_secs(5)).unwrap();
    assert!(outcome.status.success());
    assert!(!outcome.timed_out);
    assert!(outcome.worker > 0);
    assert!(!outcome.externally_reaped);
    assert_gone(outcome.worker);
}

#[test]
fn raw_failure_is_not_success() {
    let outcome = shell("exit 42", Duration::from_secs(5)).unwrap();
    assert_eq!(outcome.status.code(), Some(42));
    assert!(!outcome.timed_out);
    assert_gone(outcome.worker);
}

#[test]
fn raw_signal_is_not_success() {
    let outcome = shell("kill -TERM $$", Duration::from_secs(5)).unwrap();
    assert_eq!(outcome.status.signal(), Some(15));
    assert!(!outcome.timed_out);
    assert_gone(outcome.worker);
}

#[test]
fn timeout_waits_for_the_killed_worker() {
    let started = Instant::now();
    let outcome = run(
        Path::new("/bin/sleep"),
        &["10".into()],
        Duration::from_millis(50),
    )
    .unwrap();
    assert!(outcome.timed_out);
    assert_eq!(outcome.status.signal(), Some(9));
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_gone(outcome.worker);
}

#[test]
fn missing_worker_keeps_exec_errno() {
    let error = run(
        Path::new("/no-such-isolated-worker"),
        &[],
        Duration::from_secs(5),
    )
    .unwrap_err();
    assert_eq!(error.raw_os_error(), Some(2));
}

#[test]
fn non_executable_worker_keeps_exec_errno() {
    let error = run(Path::new("/etc/hosts"), &[], Duration::from_secs(5)).unwrap_err();
    assert_eq!(error.raw_os_error(), Some(13));
}

#[test]
fn inherited_parent_descriptor_is_excluded() {
    let file = File::open("/dev/null").unwrap();
    // SAFETY: this fixture owns the descriptor; F_SETFD clears CLOEXEC only until File drops it.
    assert_eq!(unsafe { fcntl(file.as_raw_fd(), 2, 0) }, 0);
    let outcome = shell(
        &format!("test ! -e /proc/self/fd/{}", file.as_raw_fd()),
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(outcome.status.success());
    assert!(file.metadata().is_ok());
}

#[test]
fn relative_path_is_refused() {
    let error = run(Path::new("true"), &[], Duration::from_secs(5)).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn zero_timeout_is_refused() {
    let error = run(Path::new("/bin/true"), &[], Duration::ZERO).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn timeout_overflow_is_refused() {
    let error = run(Path::new("/bin/true"), &[], Duration::MAX).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn nul_argument_is_refused() {
    let error = run(
        Path::new("/bin/true"),
        &["bad\0argument".into()],
        Duration::from_secs(5),
    )
    .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn concurrent_callers_keep_their_own_statuses() {
    let children = (20..36)
        .map(|code| {
            std::thread::spawn(move || {
                let result = shell(&format!("exit {code}"), Duration::from_secs(5)).unwrap();
                assert_eq!(result.status.code(), Some(code), "{result:?}");
                assert_gone(result.worker);
            })
        })
        .collect::<Vec<_>>();
    for child in children {
        child.join().unwrap();
    }
}
