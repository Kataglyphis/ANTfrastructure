# riscv64 venv parity (`/opt/venv` package set)

Measured on the shipped images of run `out/rebuild-20260901-r2` (`uv pip list`
inside each image):

| arch | packages |
| --- | --- |
| amd64 | 155 |
| arm64 | 153 |
| riscv64 | **47** |

109 distributions present on amd64 were absent on riscv64. None of it was in a
backlog or a parity table, so this page is the decision record.

## Mechanism

`linux/scripts/03-media/runtime/assemble-torch-app.sh` builds the venv with
`uv sync --extra ml-ai --extra docs [--extra pytorch-*]` (the `test` extra is
off: `setup-torch-venv.sh` defaults `SKIP_TORCH_TEST_EXTRAS=true`).

On riscv64 that never runs:

1. `prepare_project_tree` strips the app's `[tool.uv] environments` gate, but
   the committed `uv.lock` still records its supported environments, so
   `uv sync --frozen` aborts with

   ```
   error: The current Python platform is not compatible with the lockfile's
   supported environments: `platform_machine != 'riscv64' and sys_platform == 'linux'`, ...
   ```

2. `run_uv_sync_with_fallback` then takes its riscv64 branch and skips
   `uv lock` + `uv sync` entirely — deliberately, because the app pins
   `torch @ git+…` for riscv64 and locking would source-build torch under QEMU
   (~1 h) for metadata alone.

3. `reconcile_local_wheels` force-installs `/opt/wheels` `--no-deps`, and
   `ensure_project_package_installed` runs `uv pip install "${APP_DIR}"` —
   **`[project].dependencies` only**, no extras.

So the riscv64 venv was the local wheels plus the app's nine pure-Python core
deps. The extras' whole closure was missing. `uv_lock_regen` and
`build_uv_sync_args` are not involved on this path: the fallback returns before
`uv_lock_regen` is reached.

## What is closed

`ensure_project_package_installed` now follows the project install with
`uv pip install "${APP_DIR}[docs]"` (3 attempts, best-effort). The whole `docs`
closure is pure-Python; the only sdist-only member is `pyyaml`, and the project
install one line earlier has already satisfied it, so nothing source-builds
under QEMU. That is ~24 of the 109.

Ordering is load-bearing: the extras install must come **after** the project
install, and it must not replace it — if the extras resolution fails, the
project itself must still be installed or the runtime app-wheel smoke dies on
`No module named 'loguru'`.

## optuna

`optuna` is declared by the app's `ml-ai` extra and was absent from the riscv64
venv, so the VENV-SET gate named it. It is not blocked on this arch: optuna
itself ships an `any` wheel and its whole runtime closure resolves without a
compiler — `alembic`, `sqlalchemy`, `colorlog`, `tqdm` and `packaging` all
publish `any` wheels, `numpy` is already present, and `greenlet` is only an
`optional` extra so it is never pulled. It fell out transitively behind the
compiled members of the same extra (`scipy`, `scikit-learn`, `pandas`), not on
its own merits.

**Placement is load-bearing, and the first attempt got it wrong.** The install
was originally added inside `reconcile_local_wheels`, which is two problems at
once:

1. It runs *before* `ensure_project_package_installed`, and optuna requires
   `PyYAML` — the one member of this closure that publishes **no** `any` wheel
   and **no** riscv64 wheel, only an sdist. Installed at that point it would
   source-build under emulation; installed after the project install it is
   already satisfied, which is the same reason the `docs` extra is ordered the
   way it is.
2. It sat under `if [ "${#other_wheels[@]}" -gt 0 ]` — a condition about the
   ONNX Runtime wheel set that has nothing to do with optuna. With no local
   `other_wheels`, optuna would silently never be installed.

It now lives in `install_fallback_project_extras`, which runs only on the
riscv64 fallback path (the amd64/arm64 probe returns early, and there uv sync
already installed it) and only after `uv pip install "${APP_DIR}"`. Both
problems go away with the move; no new condition was needed.

`protobuf` and `flatbuffers` deliberately stay next to the ORT wheel in
`reconcile_local_wheels`: they are the wheel's own dangling edges, both have
zero runtime dependencies, so neither ordering concern above applies to them.

## What stays absent, and why

The `ml-ai` extra cannot be installed on riscv64 at all:

* its riscv64 branch is `opencv-python @ git+https://github.com/opencv/opencv-python.git`,
  which would clone and source-build OpenCV under QEMU;
* `uv pip install` has no `--no-install-package`, so that entry cannot be
  skipped the way `uv sync` skips it on the other arches;
* `pandas`, `scipy` and `scikit-learn` have no riscv64 wheels on PyPI
  (verified with `uv pip compile --python-platform riscv64-unknown-linux
  --only-binary :all:`), so each is a multi-hour emulated build.

A second group is gated off riscv64 by the app's own markers, i.e. it would be
absent even if `uv sync` worked here: `mlflow` (and its ~60-package closure),
`boto3`, `captum`, `onnxruntime`/`onnxruntime-genai` (ContainerHub ships local
wheels instead), and `iree-base-compiler` — riscv64 builds IREE runtime-only.

`pycairo`/`pygobject` show as missing in `uv pip list` on riscv64 but are
present as copied system packages; `import gi` works. Not a gap.

`captum` is deliberately NOT in the assert list below: it comes from the
`pytorch-*` extra, and `PYTORCH_EXTRA=none` is a supported operator override,
so requiring it would misfire on a legitimate configuration.

## The gate

`linux/scripts/06-packaging/smoke-torch-venv.sh` → `assert_app_venv_parity()`
asserts the extras actually landed. Distributions the extras must deliver are
listed in `REQUIRED`; each per-arch absence that is a decision is one line in
`EXEMPT` with its reason. A missing package that is not exempt FAILS the smoke
— including on riscv64, where the four `docs` packages are now armed. An
exemption that is no longer needed prints `??` so the table cannot rot.

The assert skips when `orchestrant` is not importable, i.e. in images that
carry a venv but never ran `assemble-torch-app.sh`.
