// SPDX-License-Identifier: MIT
// Fake adapters exercise policy and concurrency; they prove no real ABI, Windows loader or GPU inference.

#[path = "../ort_plugin_eps.rs"]
mod policy;

use policy::{
    plugin_library_path, PluginDevice, PluginLibrary, PluginRegistry, RuntimeBinding, MIGRAPHX,
};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};

type Attachment = (u32, Vec<(String, String)>);
#[derive(Default)]
struct State {
    registrations: AtomicUsize,
    enumerations: AtomicUsize,
    fail_registration: AtomicBool,
    panic_registration: AtomicBool,
    fail_enumeration: AtomicBool,
    fail_append: AtomicBool,
    devices: Mutex<Vec<PluginDevice<u32>>>,
    appended: Mutex<Vec<Attachment>>,
}

struct Binding(Weak<State>);
impl Binding {
    fn state(&self) -> Result<Arc<State>, String> {
        self.0
            .upgrade()
            .ok_or_else(|| "owning environment is gone".to_string())
    }
}
impl RuntimeBinding for Binding {
    type Options = ();
    type Device = u32;
    fn register_library(&self, name: &str, path: &Path) -> Result<(), String> {
        assert_eq!(name, MIGRAPHX.name);
        assert!(path.is_absolute() && path.is_file());
        let state = self.state()?;
        state.registrations.fetch_add(1, Ordering::SeqCst);
        assert!(
            !state.panic_registration.load(Ordering::SeqCst),
            "injected registration panic"
        );
        if state.fail_registration.load(Ordering::SeqCst) {
            return Err("registration failed 37".into());
        }
        Ok(())
    }
    fn devices(&self) -> Result<Vec<PluginDevice<u32>>, String> {
        let state = self.state()?;
        state.enumerations.fetch_add(1, Ordering::SeqCst);
        if state.fail_enumeration.load(Ordering::SeqCst) {
            return Err("enumeration failed 38".into());
        }
        let devices = state.devices.lock().unwrap().clone();
        Ok(devices)
    }
    fn append_provider(
        &self,
        _: &mut (),
        device: &u32,
        values: &[(&str, &str)],
    ) -> Result<(), String> {
        let state = self.state()?;
        if state.fail_append.load(Ordering::SeqCst) {
            return Err("attachment failed 39".into());
        }
        state.appended.lock().unwrap().push((
            *device,
            values
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        ));
        Ok(())
    }
}

struct Fixture {
    root: PathBuf,
    state: Arc<State>,
    registry: Arc<PluginRegistry<Binding>>,
}
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = PathBuf::from(std::env::var_os("ORT_PLUGIN_TEST_ROOT").unwrap())
            .join(format!("case-{}", NEXT.fetch_add(1, Ordering::SeqCst)));
        std::fs::create_dir_all(&root).unwrap();
        let state = Arc::new(State::default());
        state.devices.lock().unwrap().extend([
            PluginDevice {
                provider: "CUDAExecutionProvider".into(),
                device: 90,
            },
            PluginDevice {
                provider: "MIGraphX".into(),
                device: 11,
            },
            PluginDevice {
                provider: "MIGraphX".into(),
                device: 22,
            },
        ]);
        let registry = Arc::new(PluginRegistry::new(Binding(Arc::downgrade(&state))));
        Self {
            root,
            state,
            registry,
        }
    }
    fn module(&self, directory: &str) -> PathBuf {
        let path = self.root.join(directory);
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join(MIGRAPHX.filename), b"synthetic plugin").unwrap();
        path
    }
    fn append(&self, bundle: &Path) -> Result<(), String> {
        self.registry
            .append_provider(&mut (), &MIGRAPHX, 0, bundle, None, &[("device_id", "0")])
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn absent_optional_module_leaves_no_plugin() {
    let f = Fixture::new();
    assert_eq!(plugin_library_path(&MIGRAPHX, &f.root, None).unwrap(), None);
    assert_eq!(
        plugin_library_path(&MIGRAPHX, Path::new(""), None).unwrap(),
        None
    );
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 0);
}
#[test]
fn image_root_wins_over_bundle() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    let image = f.root.join("image");
    let module = f.module(&format!("image/{}", MIGRAPHX.root_subdirectory));
    let actual = plugin_library_path(&MIGRAPHX, &bundle, Some(image.as_os_str()))
        .unwrap()
        .unwrap();
    assert_eq!(
        actual,
        module.join(MIGRAPHX.filename).canonicalize().unwrap()
    );
}
#[test]
fn relative_advertisement_never_uses_a_good_bundle() {
    let f = Fixture::new();
    let error = plugin_library_path(
        &MIGRAPHX,
        &f.module("bundle"),
        Some(std::ffi::OsStr::new("relative")),
    )
    .unwrap_err();
    assert!(error.contains("absolute directory"));
}
#[test]
fn missing_advertised_root_never_uses_a_good_bundle() {
    let f = Fixture::new();
    assert!(plugin_library_path(
        &MIGRAPHX,
        &f.module("bundle"),
        Some(f.root.join("missing").as_os_str())
    )
    .unwrap_err()
    .contains("not a directory"));
}
#[test]
fn directory_module_is_refused() {
    let f = Fixture::new();
    std::fs::create_dir(f.root.join(MIGRAPHX.filename)).unwrap();
    assert!(plugin_library_path(&MIGRAPHX, &f.root, None)
        .unwrap_err()
        .contains("regular file"));
}
#[test]
fn relative_bundle_is_refused() {
    assert!(plugin_library_path(&MIGRAPHX, Path::new("relative"), None)
        .unwrap_err()
        .contains("absolute"));
}
#[test]
fn empty_advertisement_uses_bundle() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    assert_eq!(
        plugin_library_path(&MIGRAPHX, &bundle, Some(std::ffi::OsStr::new(""))).unwrap(),
        Some(bundle.join(MIGRAPHX.filename).canonicalize().unwrap())
    );
}
#[cfg(unix)]
#[test]
fn dangling_bundle_link_is_an_error() {
    let f = Fixture::new();
    std::os::unix::fs::symlink(f.root.join("missing"), f.root.join(MIGRAPHX.filename)).unwrap();
    assert!(plugin_library_path(&MIGRAPHX, &f.root, None)
        .unwrap_err()
        .contains("Cannot resolve"));
}
#[cfg(unix)]
#[test]
fn canonical_alias_registers_only_once() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    std::os::unix::fs::symlink(&bundle, f.root.join("alias")).unwrap();
    f.append(&bundle).unwrap();
    f.append(&f.root.join("alias")).unwrap();
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 1);
    assert_eq!(f.state.enumerations.load(Ordering::SeqCst), 2);
}
#[test]
fn failed_registration_remains_retryable() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    f.state.fail_registration.store(true, Ordering::SeqCst);
    assert_eq!(f.append(&bundle).unwrap_err(), "registration failed 37");
    f.state.fail_registration.store(false, Ordering::SeqCst);
    f.append(&bundle).unwrap();
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 2);
}
#[test]
fn successful_registration_refuses_a_different_path() {
    let f = Fixture::new();
    f.append(&f.module("first")).unwrap();
    assert!(f
        .append(&f.module("second"))
        .unwrap_err()
        .contains("already registered"));
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 1);
}
#[test]
fn selection_uses_matching_provider_ordinal_and_plain_options() {
    let f = Fixture::new();
    f.registry
        .append_provider(
            &mut (),
            &MIGRAPHX,
            1,
            &f.module("bundle"),
            None,
            &[("device_id", "1")],
        )
        .unwrap();
    assert_eq!(
        *f.state.appended.lock().unwrap(),
        [(22, vec![("device_id".into(), "1".into())])]
    );
}
#[test]
fn out_of_range_device_is_unavailable_without_attachment() {
    let f = Fixture::new();
    assert!(f
        .registry
        .append_provider(&mut (), &MIGRAPHX, 2, &f.module("bundle"), None, &[])
        .unwrap_err()
        .contains("found 2"));
    assert!(f.state.appended.lock().unwrap().is_empty());
}
#[test]
fn enumeration_error_is_not_an_empty_success() {
    let f = Fixture::new();
    f.state.fail_enumeration.store(true, Ordering::SeqCst);
    assert_eq!(
        f.append(&f.module("bundle")).unwrap_err(),
        "enumeration failed 38"
    );
    assert!(f.state.appended.lock().unwrap().is_empty());
}
#[test]
fn attachment_error_is_preserved_and_retry_does_not_reregister() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    f.state.fail_append.store(true, Ordering::SeqCst);
    assert_eq!(f.append(&bundle).unwrap_err(), "attachment failed 39");
    f.state.fail_append.store(false, Ordering::SeqCst);
    f.append(&bundle).unwrap();
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 1);
}
#[test]
fn enumeration_is_fresh_after_registration() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    f.append(&bundle).unwrap();
    f.state.devices.lock().unwrap().clear();
    assert!(f.append(&bundle).unwrap_err().contains("found 0"));
}
#[test]
fn concurrent_callers_register_once() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    std::thread::scope(|scope| {
        for _ in 0..16 {
            let registry = Arc::clone(&f.registry);
            let bundle = bundle.clone();
            scope.spawn(move || {
                registry
                    .append_provider(&mut (), &MIGRAPHX, 0, &bundle, None, &[])
                    .unwrap()
            });
        }
    });
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 1);
    assert_eq!(f.state.appended.lock().unwrap().len(), 16);
}
#[test]
fn weak_binding_does_not_keep_environment_alive() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    f.append(&bundle).unwrap();
    assert_eq!(Arc::strong_count(&f.state), 1);
    let weak = Arc::downgrade(&f.state);
    let registry = Arc::clone(&f.registry);
    drop(f);
    assert!(weak.upgrade().is_none());
    let replacement = Fixture::new();
    assert!(registry
        .append_provider(
            &mut (),
            &MIGRAPHX,
            0,
            &replacement.module("bundle"),
            None,
            &[]
        )
        .is_err());
}
#[test]
fn windows_image_module_is_at_the_root() {
    let f = Fixture::new();
    let plugin = PluginLibrary {
        name: "MIGraphX",
        root_variable: "ORT_AMDGPU_EP_ROOT",
        filename: "migraphx-ep.dll",
        root_subdirectory: "",
    };
    let module = f.root.join(plugin.filename);
    std::fs::write(&module, b"synthetic Windows layout").unwrap();
    assert_eq!(
        plugin_library_path(&plugin, Path::new(""), Some(f.root.as_os_str())).unwrap(),
        Some(module.canonicalize().unwrap())
    );
}
#[test]
fn missing_advertised_module_never_uses_a_good_bundle() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    assert!(
        plugin_library_path(&MIGRAPHX, &bundle, Some(f.root.as_os_str()))
            .unwrap_err()
            .contains("Cannot resolve")
    );
}
#[test]
fn missing_module_cannot_register() {
    let f = Fixture::new();
    assert!(f
        .append(&f.root)
        .unwrap_err()
        .contains("plugin is unavailable"));
    assert_eq!(f.state.registrations.load(Ordering::SeqCst), 0);
}
#[test]
fn poisoned_registration_lock_is_not_reused() {
    let f = Fixture::new();
    let bundle = f.module("bundle");
    f.state.panic_registration.store(true, Ordering::SeqCst);
    let registry = Arc::clone(&f.registry);
    let thread_bundle = bundle.clone();
    assert!(std::thread::spawn(move || registry.append_provider(
        &mut (),
        &MIGRAPHX,
        0,
        &thread_bundle,
        None,
        &[]
    ))
    .join()
    .is_err());
    f.state.panic_registration.store(false, Ordering::SeqCst);
    assert_eq!(
        f.append(&bundle).unwrap_err(),
        "Plugin registry lock is poisoned"
    );
}
#[test]
fn negative_control() {
    assert!(
        std::env::var_os("ORT_PLUGIN_FAIL_CONTROL").is_none(),
        "negative assertion control"
    );
}
