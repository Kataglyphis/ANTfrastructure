//! Real child/descriptor fixtures prove process transport, not HIP or cancellation of a blocked kernel request.

use super::*;
use std::fs::{File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicUsize, Ordering};

unsafe extern "C" {
    fn open(path: *const std::ffi::c_char, flags: c_int, ...) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn __errno_location() -> *mut c_int;
}

fn shell(source: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", source]);
    command
}

fn assert_reaped(pid: u32) {
    // SAFETY: WNOHANG only observes this completed child; no PID is signalled or consumed from another owner.
    assert_eq!(
        unsafe { waitpid(pid as c_int, std::ptr::null_mut(), 1) },
        -1
    );
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(ECHILD));
}

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "ant-bounded-child-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        Self(root)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn success_is_reaped_and_not_a_timeout() {
    let outcome = run(Command::new("/bin/true"), Duration::from_secs(5)).unwrap();
    assert!(outcome.status.success());
    assert!(!outcome.timed_out);
    assert_reaped(outcome.child);
}

#[test]
fn failure_keeps_its_raw_exit_code() {
    let outcome = run(shell("exit 42"), Duration::from_secs(5)).unwrap();
    assert_eq!(outcome.status.code(), Some(42));
    assert!(!outcome.timed_out);
    assert_reaped(outcome.child);
}

#[test]
fn signal_keeps_its_raw_number() {
    let outcome = run(shell("kill -TERM $$"), Duration::from_secs(5)).unwrap();
    assert_eq!(outcome.status.signal(), Some(15));
    assert!(!outcome.timed_out);
    assert_reaped(outcome.child);
}

#[test]
fn a_missing_executable_is_a_spawn_error() {
    let error = run(Command::new("/no-such-hip-helper"), Duration::from_secs(5)).unwrap_err();
    assert_eq!(error.raw_os_error(), Some(2));
}

#[test]
fn timeout_kills_and_reaps_before_returning() {
    let started = Instant::now();
    let mut command = Command::new("/bin/sleep");
    command.arg("10");
    let outcome = run(command, Duration::from_millis(50)).unwrap();
    assert!(outcome.timed_out);
    assert_eq!(outcome.status.signal(), Some(9));
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_reaped(outcome.child);
}

#[test]
fn parent_descriptors_do_not_reach_the_fresh_executable() {
    // SAFETY: open creates one descriptor, immediately transferred into File for scoped ownership.
    let raw = unsafe { open(c"/dev/null".as_ptr().cast(), 0) };
    assert!(raw >= 3);
    // SAFETY: this successful open has no other Rust owner.
    let file = unsafe { File::from_raw_fd(raw) };
    let outcome = run(
        shell(&format!("test ! -e /proc/self/fd/{}", file.as_raw_fd())),
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(outcome.status.success());
    assert!(file.metadata().is_ok());
}

unsafe extern "C" fn denied_close(_first: u32, _last: u32, _flags: c_int) -> c_int {
    // SAFETY: errno is thread-local in the post-fork child and the callback invokes no allocator.
    unsafe {
        *__errno_location() = 13;
    }
    -1
}

#[test]
fn descriptor_setup_failure_keeps_its_errno() {
    let error = run_with_close(
        Command::new("/bin/true"),
        Duration::from_secs(5),
        denied_close,
    )
    .unwrap_err();
    assert_eq!(error.raw_os_error(), Some(13));
}

#[test]
fn invalid_deadline_fails_before_starting_work() {
    let fixture = Fixture::new();
    let marker = fixture.0.join("started");
    let mut command = Command::new("/usr/bin/touch");
    command.arg(&marker);
    let error = run(command, Duration::MAX).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    assert!(!marker.exists());
}

#[test]
fn redirected_standard_streams_survive_descriptor_isolation() {
    let fixture = Fixture::new();
    let input = fixture.0.join("input");
    let output = fixture.0.join("output");
    let error = fixture.0.join("error");
    std::fs::write(&input, "payload\n").unwrap();
    let mut command = shell("read -r value; printf '%s' \"$value\"; printf diagnostic >&2");
    command.stdin(Stdio::from(File::open(input).unwrap()));
    command.stdout(Stdio::from(File::create(&output).unwrap()));
    command.stderr(Stdio::from(File::create(&error).unwrap()));
    let outcome = run(command, Duration::from_secs(5)).unwrap();
    assert!(outcome.status.success());
    assert_eq!(std::fs::read_to_string(output).unwrap(), "payload");
    assert_eq!(std::fs::read_to_string(error).unwrap(), "diagnostic");
}

#[test]
fn a_non_executable_file_is_not_an_answer() {
    let fixture = Fixture::new();
    let helper = fixture.0.join("helper");
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&helper)
        .unwrap();
    let error = run(Command::new(helper), Duration::from_secs(5)).unwrap_err();
    assert_eq!(error.raw_os_error(), Some(13));
}
