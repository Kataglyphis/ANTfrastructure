<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# What `:latest-cross` promises its consumers

This page is the **contract** side of the runtime image: the properties another
repository's CI lane may build on, written down so they are a promise rather
than an accident of the last build. Everything here is asserted per arch by
`check_consumer_contract` in `linux/scripts/06-packaging/smoke-runtime-image.sh`,
against the shipped bytes, as the user the image ships.

It exists because on 2026-09-04 four properties a consuming lane depended on were
all broken at once in `:latest-cross`, every runtime gate stayed green, and the
lane in the other repo is where they were found. A property nobody wrote down is
a property nothing can keep.

## The contract

Run as the image's own user (`kataglyphis`, uid 1001), with no privileged flags
and no extra `-e`:

| # | Promise | Consumer symptom when it breaks |
|---|---|---|
| 1 | `CCACHE_DIR` and `SCCACHE_DIR` point **outside** `/workspace` and are writable | the cache is written into the consumer's bind-mounted checkout, pollutes their working tree, can be swept into CI artifacts, and on a non-ext4 host mount `flatpak-builder` aborts: *"Can't initialize ccache use: Failed to set permissions of /workspace/.ccache/disabled/ccache.conf: Operation not permitted"* |
| 2 | `$RUSTUP_HOME/tmp` and `$CARGO_HOME` are writable | *"could not create temp file …: Permission denied (os error 13)"* — Corrosion, cargokit and `flutter_rust_bridge_codegen` cannot run. Not workaroundable by redirecting the variable: the toolchains live in that tree, and `rustup toolchain install` (fRB asks for the `nightly` channel, the image pins a dated nightly) writes there too |
| 3 | `ANDROID_HOME` and `ANDROID_SDK_ROOT` are set, `$ANDROID_HOME/platform-tools` exists, and the SDK's `cmdline-tools/latest/bin` + `platform-tools` are on `PATH` | `flutter build apk` stops with *"[!] No Android SDK found"*. Under CodeQL's `database create --command=…` the exit 1 aborts before the database is finalised, so the lane reports *"bundle source directory not found: build/app/outputs/flutter-apk"* — three steps from the cause |
| 4 | `java` is on `PATH` and `JAVA_HOME` names a JDK with `bin/javac` | Gradle stops the Android lane with *"JAVA_HOME is not set and no 'java' command could be found in your PATH"*, and `flutter doctor` reports *"No Java Development Kit (JDK) found"* |
| 5 | `appimagetool` is READABLE by the image user, not merely executable | it is an AppImage and reads `/proc/self/exe` for its own squashfs offset, so mode 711 gives *"Cannot open /proc/self/exe: Permission denied"* and produces no `.AppImage` |
| 6 | Every path under `/opt/flutter` is owned by uid 1001, `packages/flutter_tools/.dart_tool` included | `flutter pub get` fails with *"Cannot open file … package_config.json (OS Error: Permission denied, errno = 13)"* |

Row 6 is the one a consumer **cannot** repair at runtime. The directory sits in a
read-only overlay layer, so a non-owner can neither empty nor rename it — both
were attempted and refused — and the only workaround is mounting a tmpfs with
`mode=1777` over it. Rows 1–5 are merely expensive to work around, and the point
of writing them down is that nobody should have to.

`/workspace` is the WORKDIR and the consumer's checkout. Nothing the image
generates by itself may land there; that is what makes row 1 a location
assertion and not only a permission one.

The compiler-cache defaults the shared library already declares
(`linux/scripts/01-core/compiler-cache.sh`) are `/var/cache/ccache` and
`/var/cache/sccache`, and the image ships both as `drwxrwxrwt`. An image ENV
that contradicts our own library is the failure shape row 1 guards.

**Neither cache directory is a `VOLUME`.** The image declares exactly one,
`/workspace` (`Dockerfile.torch:118`, confirmed in `Config.Volumes` of all three
shipped children), so a container's compiler cache lives in its writable layer
and dies with it. A lane that wants the cache to survive has to mount something
there itself — and that is the reason row 1 is a LOCATION assertion: a cache
pointed back into the bind-mounted checkout would persist, by polluting the
consumer's working tree.


### The Android lane needs a JDK

`02-toolchain/android-sdk.sh` installs the full `openjdk-21-jdk` in the stage
that BUILDS the SDK, but `Dockerfile.package` copies only `/opt/android-sdk` —
apt had put the JDK in `/usr/lib/jvm`, which is not part of that COPY. The
runtime image therefore carried a complete Android SDK and no Java at all, and
the failure surfaces in Gradle rather than in Flutter, one layer below where a
reader looks.

The runtime image installs `JDK_PACKAGE` (`01-core/versions.env`,
`openjdk-21-jdk-headless`, ~286 MB with its JRE) by name rather than through
`append_available_packages`, which SKIPS what apt does not have: a silently
skipped JDK would ship the same broken image the gate exists to catch. Headless
is deliberate — a container build needs `javac`, not AWT.

`JAVA_HOME` cannot be written literally, because Ubuntu's path carries both the
version and the architecture (`java-21-openjdk-riscv64`). `anchor_java_home`
resolves it once from the installed `javac` and parks the symlink
`/usr/lib/jvm/default-java`, which the image ENV names. A JDK bump then needs no
Dockerfile edit, and a JDK that installed no compiler fails the stage instead of
shipping a JRE that Gradle cannot use.


### Executable is not usable

`ensure_appimagetool` (`02-toolchain/packaging-deps.sh`) downloads into a
`mktemp` file, which is `0600`, and made it executable with `chmod +x` — which
adds the x bits and leaves r for the owner only, i.e. `0711`. `mv` carries that
mode to `/usr/local/bin/appimagetool`, so the tool was executable by everyone
and readable by root alone.

That is fatal for this particular tool and invisible for most others:
appimagetool is itself an AppImage, so it opens `/proc/self/exe` to find where
its squashfs payload starts. As uid 1001 that open is refused and the run dies
with `Failed to get fs offset for /proc/self/exe`, having produced nothing.

The install site now sets `0755` explicitly rather than relying on `+x` over
whatever mode the download landed with, and the contract gate asserts
readability rather than presence — `command -v` finding it says nothing about
whether the image's own user can run it.

## How the gate proves it

One `nerdctl run`, not one per assertion. `_consumer_contract_probe` emits facts
only — `WHO`, `ENV`, `WRITE`, `DIR`, `FACT` lines and a `CCPROBE_DONE` sentinel —
and `_consumer_contract_verdicts` reaches every verdict on the host, so each
failure path is provable from a *recorded* probe capture rather than from a
doctored 30 GB image. `linux/scripts/tests/test-runtime-image-gates.sh` drives it
with the capture measured in the broken 2026-09-04 image and with the fixed one.

Three details are load-bearing:

- **Writability is a real `mkdir` + create + delete**, not `[ -w ]`. `access(2)`
  answers yes for uid 0 and says nothing about a read-only layer.
- **The probe must have run as the image's own `Config.User`.** As root every
  directory answers writable, so a probe that reports any other identity fails
  the gate outright instead of reporting seven green rows.
- **No row may report nothing.** A missing fact is `NOFACT` and fails, an empty
  row table fails as *asserted NOTHING*, and a verdict verb no arm handles fails.
  A gate arm that can only ever skip is how all four defects shipped.

Each red row quotes the symptom from the *consuming* repository's log, not our
path, because that is the sentence someone will paste into a search.

## Per-arch exemptions

`_consumer_contract_exempt` is a `<arch>:<row>` table, same contract as
`_parity_exempt`: listed means reviewed, and an arm that **stops** applying fails
so the table cannot rot in place. Each arm is re-checked by **its own** probe
fact, named by `_consumer_exempt_fact`; `yes` is `STALE` and names the arm for
deletion, a missing fact is `NOFACT` and never a grant.

Two arms, both `riscv64`, both measured on the image shipped 2026-09-05 rather
than argued from the build graph:

| arm | rot fact | what the riscv64 image reports |
|---|---|---|
| `dart-tool` | `flutter-sdk` | `/opt/flutter` exists and is **empty**, so `packages/flutter_tools/.dart_tool` is absent and the row would read as unwritable. Upstream publishes no riscv64 SDK; `check_flutter` asserts that absence instead |
| `appimagetool` | `appimagetool-readable` | no `appimagetool` on `PATH` at all — `packaging-deps.sh`'s asset table covers x86_64/aarch64/armhf/i686 and refuses the rest |

`flutter-owner` **was** a third arm and is gone. The same probe measures
`find /opt/flutter ! -uid 1001` as **0** on riscv64, which is the row *passing*,
not a row to skip: an empty tree owned by the runtime uid satisfies the promise.
Exempting it also hid the defect the row exists for — a root-written SDK would
have read as a documented exception on that arch. Until 2026-09-05 the
`appimagetool` arm was re-checked with `FACT flutter-sdk`, i.e. by another row's
fact, so a riscv64 appimagetool could never have been noticed; that is what
`_consumer_exempt_fact` fixes.

The Android SDK is **not** exempt anywhere. `/opt/android-sdk/platform-tools`
was measured present in all three shipped arches on 2026-09-04, and the parity
table already asserts the `android-sdk` prefix on every arch.

### The web lane toolchain

Measured in a consumer run, the Flutter **web** lane rebuilt its own tools on every
invocation: `flutter_rust_bridge_codegen build-web` shells out to `wasm-pack`, and
both were a from-source `cargo install` — 258 crates for `wasm-pack`, 174 for
`flutter_rust_bridge_codegen` — followed by a nightly `rustup` auto-install through
a path rustup itself calls deprecated.

The image now installs all three ahead of time:

| what | pin | why it must be here |
| --- | --- | --- |
| `nightly` toolchain + `rust-src` + `wasm32-unknown-unknown` | channel | `wasm-pack -Z build-std` runs `cargo +nightly`, which resolves the **channel name**, not a dated pin — so `install-rust.sh`'s dated pin does not satisfy it |
| `wasm-pack` | `WASM_PACK_VERSION` | 258 crates per consumer run |
| `flutter_rust_bridge_codegen` | `FLUTTER_RUST_BRIDGE_VERSION` | 174 crates per consumer run |

Both crate versions live in `01-core/versions.env` and are installed with
`cargo install --locked`, so a consumer gets the pinned build rather than whatever
the index resolves to that day.

`install_web_lane_toolchain` is **non-fatal throughout** — a missing nightly channel,
an unpinned version and a failed `cargo install` each `WARN` and continue. The
trade is deliberate: a consumer that has to build its own tools is slow, a consumer
that cannot build the image at all is worse.

### The AppImage runtime ships with the tool

Every AppImage begins with a small ELF **runtime** that `appimagetool` prepends to
the payload. When that runtime is not already on disk, `appimagetool` fetches it
from GitHub on each run — so a consumer's packaging step depends on GitHub being up
at build time, and fails offline.

The runtime is staged at image-build time instead, and it is **not downloaded**.
Upstream publishes it only under the moving `continuous` tag, which is the exact
mutable-asset trap that already broke `appimagetool` itself once (a `continuous`
re-upload changed the bytes under a pinned SHA256, and `download_verified_file`
reported a tamper-shaped "checksum mismatch" that was only upstream drift). Since
every AppImage *starts* with the runtime, and `appimagetool` is itself an AppImage
pinned to an immutable versioned tag with a recorded SHA256, the runtime is taken
out of the tool's own first `--appimage-offset` bytes. It is therefore pinned
transitively and arch-correct by construction — no second download, no second pin
to keep in step.

It is written to two places, as `runtime-<uname -m>`:

| path | why |
| --- | --- |
| `/etc/skel/.local/share/appimagekit/` | the runtime user is created later, and inherits `/etc/skel` |
| `${HOME}/.local/share/appimagekit/` | the build user that runs the packaging step now |

`ensure_appimagetool_runtime` is a no-op, not a failure, when `appimagetool` is
absent (riscv64 has no upstream build) or when it does not report a numeric offset:
a missing runtime costs a consumer one download, and is never worth failing a
toolchain stage over.

### The Android SDK roots are advertised

`Dockerfile.android` advertises where each Android payload lives; `Dockerfile.package`
COPYs the payload those names point at but, until 2026-09-05, never re-declared the
names. A consumer that found `/opt/android` in the runtime image therefore still had
no way to be told where anything inside it was, and every Android lane hardcoded the
paths or re-downloaded the SDKs. The runtime image now re-declares all six:

| variable | value |
| --- | --- |
| `GSTREAMER_ROOT_ANDROID` | `/opt/android/gstreamer` |
| `ONNXRUNTIME_ROOT_ANDROID` | `/opt/android/onnxruntime` |
| `LITERT_ROOT_ANDROID` | `/opt/android/litert` |
| `OPENCV_ROOT_ANDROID` | `/opt/android/opencv` |
| `IREE_ROOT_ANDROID` | `/opt/android/iree` |
| `OPENCV_ANDROID_JNI_DIR` | `/opt/android/opencv/sdk/native/jni` |

Two shapes here are deliberate and a tidy-up would break both. Each name gets its
**own** `ENV` instruction, because the env-knob owner scan reads only the first name
of an instruction — collapsing them into one backslash-continued `ENV`, the way
`Dockerfile.android` writes them, would leave five of the six with no recorded owner.
And the OpenCV key is `OPENCV_ROOT_ANDROID`, never a bare `OpenCV_DIR`: that is the
name `find_package(OpenCV)` reads, so pointing it at the Android SDK would hijack
every **Linux** OpenCV consumer in the same image.

These are paths, not versions, so they are outside the advertised-version-key gate
(`verify_advertised_keys.py`); what holds them is the runtime smoke's path checks.

## Two things worth knowing before you configure a lane

- `:latest-cross` is a proper multi-arch index. An arm64 runner gets arm64
  binaries; there is no longer any reason to pin `-amd64` and no `rustc: 1: ELF:
  not found` to work around.
- **The image ships Flutter at `/opt/flutter`.** A lane still passing
  `--flutter-dir /workspace/flutter` re-downloads the whole SDK every run for
  nothing. `sccache` and `appimagetool` are on `PATH` as well.

## The Android SDK roots are advertised

`Dockerfile.android` sets `GSTREAMER_ROOT_ANDROID`, `ONNXRUNTIME_ROOT_ANDROID`,
`LITERT_ROOT_ANDROID`, `OPENCV_ROOT_ANDROID` and `IREE_ROOT_ANDROID`, but that is
the *build* stage. `Dockerfile.package` COPYs the payload those names point at and
used to stop there, so a consumer of the shipped image found `/opt/android`
populated and no name telling it what was where. The reported symptom:

```
CMake Error at CMakeLists.txt:18 (message):
  GSTREAMER_ROOT_ANDROID must be set
```

All five are re-declared in the runtime image, one `ENV` instruction each — the
env-knob owner scan reads the first name of an instruction only, so a single
multi-name `ENV` would leave four of them unowned.

There is deliberately **no** bare `OpenCV_DIR`. That is the name
`find_package(OpenCV)` resolves, and pointing it at the Android SDK would hijack
every *Linux* OpenCV consumer in the same image. `OPENCV_ANDROID_JNI_DIR` names
the Android tree instead, to be passed explicitly:

```bash
cmake -DOpenCV_DIR="${OPENCV_ANDROID_JNI_DIR}" ...
```

## What the image stages so a run does not

Three of the contract rows are not about permissions at all. They ask whether a
thing is *present*, because the alternative is that every consumer run fetches or
rebuilds it. Measured in one consumer's build on 2026-09-05, before the fix:

| Row | Absent means |
| --- | --- |
| `flatpak-runtimes` | `flatpak list --runtime` returns **0 refs**; seven `org.freedesktop` refs, ~1.9 GB, re-downloaded per run per arch |
| `appimage-runtime` | `appimagetool` refetches `runtime-<arch>` from GitHub, so packaging hangs on GitHub being reachable |
| `web-lane-tools` | `wasm-pack` (258 crates) and `flutter_rust_bridge_codegen` (174) are `cargo install`ed from source in every run |

They share one verdict function; the cost of each is written down once, in
`_consumer_contract_symptom`, which is also what the failure message prints.

### The Flatpak runtimes ship with the image

`install_flatpak_runtime` had existed for months behind
`INSTALL_FLATPAK_RUNTIMES`, which defaulted to **false** — so the capability was
there and switched off, and it covered two of the seven refs. It now defaults to
true and installs all seven, `Platform.GL.default` twice because the base branch
and its `extra` sibling are separate refs.

Flathub builds these for x86_64 and aarch64 only. On any other arch the install is
a guaranteed 404 rather than a flake, so the function returns early and the row is
exempt on riscv64.

### The AppImage runtime ships with the tool

`appimagetool` embeds a type-2 runtime into every AppImage it builds, and fetches
it at build time if it is not on disk. Upstream publishes that runtime **only**
under the moving `continuous` tag — the exact mutable-asset trap that made
`appimagetool` itself move to a pinned version tag (TS1, 2026-08-15), so it cannot
be SHA-pinned.

It is not downloaded. Every AppImage *begins* with that runtime, and
`appimagetool` is already SHA-pinned, so `ensure_appimagetool_runtime` reads the
offset the tool reports for itself and copies its own first bytes out. Pinned
transitively, correct by construction for whatever arch the tool is. It lands in
`/etc/skel` as well as root's home, so the runtime user created later inherits it.

### The web-lane toolchain

`flutter_rust_bridge_codegen build-web` shells out to `wasm-pack ... -Z build-std`,
which resolves the nightly **channel**. The dated pin `install-rust.sh` adds is not
that name, so rustup auto-installed one per run through a path it calls deprecated.
The package stage installs the `nightly` channel with `rust-src` and
`wasm32-unknown-unknown`, plus both binaries at pinned versions, on a cargo
registry cachemount.

`WASM_PACK_VERSION` and `FLUTTER_RUST_BRIDGE_VERSION` are advertised as image ENV
and compared against what the binaries report, which is also the proof that they
are installed. Every step is non-fatal: a consumer that has to build its own tools
is slow, an image that cannot be built at all is worse.
