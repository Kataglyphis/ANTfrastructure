<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# What `:latest` promises its consumers

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
`/workspace` (`VOLUME ["${WORKDIR}"]` in `Dockerfile.torch`, confirmed in
`Config.Volumes` of all three shipped children), so a container's compiler cache lives in its writable layer
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

- **Writability is a real create + delete** of a file in the directory, not
  `[ -w ]`. `access(2)` answers yes for uid 0 and says nothing about a read-only layer.
- **The probe must have run as the image's own `Config.User`.** As root every
  directory answers writable, so a probe that reports any other identity fails
  the gate outright instead of reporting every row green.
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

Four arms, all `riscv64`. The first two were measured on the image shipped
2026-09-05 rather than argued from the build graph:

| arm | rot fact | what the riscv64 image reports |
|---|---|---|
| `dart-tool` | `flutter-sdk` | `/opt/flutter` exists and is **empty**, so `packages/flutter_tools/.dart_tool` is absent and the row would read as unwritable. Upstream publishes no riscv64 SDK; `check_flutter` asserts that absence instead |
| `appimagetool` | `appimagetool-readable` | no `appimagetool` on `PATH` at all — `packaging-deps.sh`'s asset table covers x86_64/aarch64/armhf/i686 and refuses the rest |
| `flatpak-runtimes` | `flutter-sdk` | no refs: Flathub builds the freedesktop runtimes for x86_64 and aarch64 only, and the installer skips every other arch |
| `appimage-runtime` | `flutter-sdk` | no runtime: it is carved out of `appimagetool`, which riscv64 does not have |

**Open gap (2026-09-25):** the last two arms are re-checked by `flutter-sdk`,
another row's fact, because `_consumer_exempt_fact` maps every row but
`appimagetool` to it. A riscv64 image that gained Flatpak runtimes or an AppImage
runtime would still read `EXEMPT`, which is the rot the next paragraph describes.

`flutter-owner` **was** an arm too and is gone. The same probe measures
`find /opt/flutter ! -uid 1001` as **0** on riscv64, which is the row *passing*,
not a row to skip: an empty tree owned by the runtime uid satisfies the promise.
Exempting it also hid the defect the row exists for — a root-written SDK would
have read as a documented exception on that arch. Until 2026-09-05 the
`appimagetool` arm was re-checked with `FACT flutter-sdk`, i.e. by another row's
fact, so a riscv64 appimagetool could never have been noticed; that is what
`_consumer_exempt_fact` fixes.

The Android SDK is **not** exempt anywhere. `/opt/android-sdk/platform-tools`
was measured present in all three shipped arches on 2026-09-04, and the parity
table already asserts the `android-sdk` prefix on every arch. The row is
*skipped*, not exempted, only when the image says it ships no SDK: an android
stage built on a non-amd64 host has no NDK to install (upstream ships it for
`linux-x86_64` only), and `android-sdk.sh` records that in
`/opt/android/.android-payload-off`. A missing fact is still `NOFACT`.

### The Flatpak runtimes ship with the image

`flatpak list --runtime` in the shipped image returned **zero refs**. Every consumer
run therefore re-downloaded the whole runtime set — roughly 1.9 GB across seven refs,
the single largest download in their build.

Two of the seven (`Platform` and `Sdk`) were already installed here; the other five
were left to each consumer run. All seven are installed now:

| ref | pinned by |
| --- | --- |
| `org.freedesktop.Platform//<ver>` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Sdk//<ver>` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Platform.Locale//<ver>` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Sdk.Locale//<ver>` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Platform.GL.default//<ver>` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Platform.GL.default//<ver>extra` | `FLATPAK_RUNTIME_VERSION` |
| `org.freedesktop.Platform.openh264//<ver>` | `FLATPAK_OPENH264_VERSION` |

`GL.default` appears twice on purpose: the base branch and its `extra` sibling are
two separate refs, and a build that resolves one still fetches the other.

`INSTALL_FLATPAK_RUNTIMES` defaults to **true** since 2026-09-05. Flathub builds
these for `x86_64` and `aarch64` only, so on any other architecture the install is a
guaranteed 404 rather than a transient failure — the installer skips those arches
outright instead of retrying, and riscv64 images ship without Flatpak runtimes by
construction.

### The web lane toolchain

Measured in a consumer run, the Flutter **web** lane rebuilt its own tools on every
invocation: `flutter_rust_bridge_codegen build-web` shells out to `wasm-pack`, and
both were a from-source `cargo install` — 258 crates for `wasm-pack`, 174 for
`flutter_rust_bridge_codegen` — followed by a nightly `rustup` auto-install through
a path rustup itself calls deprecated.

The image now installs all three ahead of time:

| what | pin | why it must be here |
| --- | --- | --- |
| `nightly` toolchain + `rust-src` + `wasm32-unknown-unknown` | `RUST_NIGHTLY_TOOLCHAIN` (`nightly-YYYY-MM-DD`) | `flutter_rust_bridge_codegen build-web` runs wasm-pack with `RUSTUP_TOOLCHAIN=nightly` and `-Z build-std`. A **dated** toolchain is immutable, so `rustup toolchain install <pin>` is a genuine no-op on a warm image; the floating channel is UPDATED by that command, and the update renames files out of the read-only image layer (`Invalid cross-device link`). Consumers that still name the channel get it auto-installed at runtime into the writable `RUSTUP_HOME` — works, but pays the download per run; FRB's `--wasm-pack-rustup-toolchain` names the pin instead. |
| `wasm-pack` | `WASM_PACK_VERSION` | 258 crates per consumer run |
| `flutter_rust_bridge_codegen` | `FLUTTER_RUST_BRIDGE_VERSION` | 174 crates per consumer run |

Both crate versions live in `01-core/versions.env`. Where upstream publishes a
release binary for the arch, the image takes that instead of compiling: the same
two `cargo install`s cost 87 s / 113 s on amd64 but **768 s / ~1170 s on arm64**
and **1813 s / 3500 s on riscv64**, which is the shape of QEMU user-mode
emulation rather than a defect. `install_web_lane_prebuilt` downloads the
`x86_64-` or `aarch64-unknown-linux-musl` asset and verifies it against a
per-arch `*_SHA256` pin in `versions.env`, the way sccache and binaryen are
already fetched. Anything else — riscv64, which upstream publishes no asset for,
a missing pin, a failed or mismatching download, a tarball without the binary in
it — falls back to the from-source leg
([below](#building-the-web-lane-tools-from-source)), so a consumer still gets the
pinned `--locked` build rather than whatever the index resolves to that day, and
nothing unverified is ever installed. **The four hashes bump with the two
versions.**

That leaves one open question rather than an assumption: whether a riscv64 web
lane exists at all. The tools are installed uniformly because an arch-conditional
image is harder to reason about than a slower one, and because "we assumed nobody
uses it" is how the Android layer ended up built for the wrong ABI.

`install_web_lane_toolchain` is **non-fatal for availability** — a missing nightly
pin, an unpinned version and a failed `cargo install` each `WARN` and continue. The
trade is deliberate: a consumer that has to build its own tools is slow, a consumer
that cannot build the image at all is worse. What it does fail on — a bad knob, or
a binary that claims to be good and is not — is in the next section.

### Building the web-lane tools from source

riscv64 has no upstream binary, so its package stage used to compile both tools
under QEMU on every chain: 960 s + 1,665 s of a 3,384 s RUN (riscv64 layer file
times, 2026-09-22). That compile now has two replacements, and the old build stays
one switch away, verbatim. Owner decision 2026-09-23: both options, cross the default.

| Path | Where it compiles | When |
| --- | --- | --- |
| cross | `Dockerfile.android`, stage `web-lane-tools`: `cargo install --target <triple>` under the hub's own `setup_linux_cross_env`, before `final` swaps the amd64-hosted cross GCC out | the target is in `WEB_LANE_TOOLS_CROSS_ARCHES` and is not the build platform's own arch |
| native | the package stage, with rv64gc Rust: `cargo install --locked <tool> --version <pin> --root <scratch>` under QEMU on the amd64 host, natively on a riscv64 or arm64 build host | `WEB_LANE_TOOLS_SOURCE=native`, or when `auto` finds no usable cross artifact |
| cache | the package stage's cachemount `web-lane-tools-bin-<arch>` | a native build whose exact key was built before |
| legacy | the package stage, exactly as before 2026-09-23: `cargo install --locked <tool> --version <pin>` into `CARGO_HOME` | `WEB_LANE_TOOLS_SOURCE=legacy` only |

**native is not the old build.** It compiles where the old build did, with the same
rv64gc Rust, but four things differ: it forces vendored static bzip2, xz and zstd
(the old build linked whatever pkg-config found in the stage); it installs a bare
binary copied out of a scratch `--root`, so `CARGO_HOME` has no `.crates.toml` /
`.crates2.json` entry for it; a binary that fails the gate stops the build (the old
build installed anything cargo produced); and it reads the cache first, so it may
not compile at all (`WEB_LANE_TOOLS_CACHE=refresh` or `off` forces a compile).
**legacy** is the old build, verbatim: cargo installs into `CARGO_HOME` itself (and
records it there), in the stage's own environment, with no gate, no cache, no
provenance line, and a failed `cargo install` only WARNs. It ignores
`WEB_LANE_TOOLS_CACHE` and never reads the cross artifact.

amd64 and arm64 are untouched: they install upstream's sha-pinned musl binary
first and reach this code only if that download fails.

**Picking a path.** Export `WEB_LANE_TOOLS_SOURCE` before `build-cross-chain.sh` or
the runtime helpers:

- `auto` (default) takes the cross artifact when its manifest says `status=ok`, it
  was built for this exact key, and it passes the gate. Anything else builds
  natively, with a `WARN` that ends `the cross fast path was not taken`.
- `cross` requires the artifact: absent, `failed` or another key is an ERROR. A
  `skipped` manifest is not, because the producer was never asked to build that
  arch; the package builds natively.
- `native` never reads the artifact. It still reads the cache, so add
  `WEB_LANE_TOOLS_CACHE=refresh` for a guaranteed fresh compile.
- `legacy` is the build the package stage ran before 2026-09-23, unchanged (above).
  Use it to rule the new paths out, or when a consumer needs cargo's install record.

`WEB_LANE_TOOLS_CACHE` is `on` (default), `refresh` (never read an entry, store the
new build) or `off` (neither). `RUNTIME_NO_CACHE=1` does not empty a cachemount;
`refresh` is its equivalent here. `WEB_LANE_TOOLS_CROSS_ARCHES` (default `riscv64`,
a comma list, or `none`) is the arches android cross-builds for. A build host whose
own arch is the target — the riscv64 X100, an arm64 Jetson on
`CROSS_BUILD_PLATFORM=linux/arm64` — always gets `skipped: native-build-platform`,
so `auto` builds natively there with nothing set.

All three are Dockerfile ARGs that `lib-orchestrator.sh` forwards only when they are
set, so leaving them unset moves no cache key. They are deliberately not in
`versions.env`: a line there re-keys the whole chain from base.

**The key.** Eight fields: schema, tool, version, target triple, rustc release,
RUSTFLAGS, the C environment and `--locked`. Who built it (`built_by=cross:amd64`,
`native:riscv64`) is recorded, never keyed. The cross key carries cross-env.sh's
RVV flags (`-C target-feature=+v,+zvl128b`; a test pins the copy); the native key
carries none, as the old build never set any. Both force vendored static bzip2,
xz and zstd, because under `PKG_CONFIG_ALLOW_CROSS` those `-sys` crates link the
build host's library
([failure-modes.md](failure-modes.md#a-cross-built-rust-tool-links-the-build-hosts-libbz2)).
`legacy` has no key: it caches nothing.

**The gate** (`wlt_assert_binary`) reads the staged bytes before anything is
installed: ELF64, the arch's machine, lp64d on riscv64, glibc's own loader as
`PT_INTERP`, `NEEDED` only from libc's family, no `GLIBC_` version above the
image's glibc, and `--version` printing exactly `<tool> <pin>`. No readelf is a
refusal, not a skip. Artifact and cache entries must also match their recorded
sha256.

**Fatal or not.** Availability still only WARNs: a failed `cargo install`, a
producer that could not build (it records `status=failed` and android stays
green), an unusable artifact under `auto`, no `rustc -V` release under `auto` or
`native`. These fail the package stage: a bad knob value, checked before anything
else, so a typo stops amd64 and arm64 too; a binary that claims to be good and is
not — a `status=ok` artifact failing its sha or its gate, in `auto` and `cross`
alike, or a native build cargo reported as a success that fails the gate; an image
whose glibc `getconf` cannot report, or an `install` into `CARGO_HOME/bin` that
fails; and `cross` with no usable artifact, including no `rustc -V` release to key
an expected one by. A cache entry that fails its checks is deleted with a `WARN`
and rebuilt. `legacy` fails on nothing but a bad knob.

**Provenance.** Each cross, cache or native install appends `tool= version=
source=cross|cache|native sha256= key=` to `/usr/local/share/web-lane-tools/provenance`.
All three install a bare binary with no `.crates.toml`, which is what amd64 and arm64
already ship from upstream: a consumer's own `cargo install <tool>` then stops on
`binary already exists` unless it passes `--force`. `legacy` writes no provenance
line, and cargo records its install, as before.

**Not covered.** Behaviour beyond `--version`: no automated riscv64 `build-web`
consumer exists. A binary and manifest forged consistently by someone who can write
the build host's cachemounts, the same trust boundary as the cargo, uv and apt
mounts. The Jetson → riscv64 cross leg is untested; it records `failed` and falls
back. The cross build ran in a probe (about 73 s at 32 vCPU, 2026-09-22), never yet
in a chain.

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
out of the tool's own bytes, up to where its squashfs payload starts. It is
therefore pinned transitively and arch-correct by construction — no second
download, no second pin to keep in step.

The offset is found by reading the file for the squashfs superblock, never by
running the tool: QEMU user-mode cannot self-mount a foreign-arch AppImage, and
`appimagetool --appimage-offset` gave `Exec format error` on aarch64 (2026-09-06).

It is written to two places, as `runtime-<uname -m>`:

| path | why |
| --- | --- |
| `/etc/skel/.local/share/appimagekit/` | the runtime user is created later, and inherits `/etc/skel` |
| `${HOME}/.local/share/appimagekit/` | the build user that runs the packaging step now |

`ensure_appimagetool_runtime` is a no-op, not a failure, when `appimagetool` is
absent (riscv64 has no upstream build) or when no squashfs superblock is found in it:
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

- `:latest` is a proper multi-arch index (it was called `:latest-cross` until
  2026-09-22; that name is retired). An arm64 runner gets arm64
  binaries; there is no longer any reason to pin `-amd64` and no `rustc: 1: ELF:
  not found` to work around.
- **The image ships Flutter at `/opt/flutter`**, the default of the hub's
  `flutter_lane_prepare_env` (`05-frameworks/flutter/lane-prologue.sh`), which
  installs nothing: a lane that points it at `/workspace/flutter` stops with
  `no Flutter SDK at /workspace/flutter`, and a lane with its own installer
  re-downloads the SDK every run for nothing. `sccache` and `appimagetool` are on
  `PATH` as well.

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

All five are re-declared in the runtime image, with `OPENCV_ANDROID_JNI_DIR`
beside them, one `ENV` instruction each — the env-knob owner scan reads the first
name of an instruction only, so a single multi-name `ENV` would leave five of the
six unowned.

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
`appimagetool` is already SHA-pinned, so `ensure_appimagetool_runtime` finds the
squashfs superblock in the tool's file and copies the bytes before it out. Pinned
transitively, correct by construction for whatever arch the tool is. It lands in
`/etc/skel` as well as root's home, so the runtime user created later inherits it.

### The web-lane toolchain

`flutter_rust_bridge_codegen build-web` shells out to `wasm-pack ... -Z build-std`,
which resolves the nightly **channel** unless FRB's `--wasm-pack-rustup-toolchain`
names the pin, so rustup auto-installed one per run through a path it calls
deprecated. The package stage installs the dated pin `RUST_NIGHTLY_TOOLCHAIN`, not
the channel ([why](#the-web-lane-toolchain)), with `rust-src` and
`wasm32-unknown-unknown`, plus both binaries at pinned versions, on a cargo
registry cachemount.

`WASM_PACK_VERSION` and `FLUTTER_RUST_BRIDGE_VERSION` are advertised as image ENV
and compared against what the binaries report, which is also the proof that they
are installed. A slow consumer beats an image that cannot be built, so only a
defect fails the stage; riscv64's from-source leg is
[above](#building-the-web-lane-tools-from-source).

## The ort crate links the chain ONNX Runtime

Both published images set the environment of the Rust `ort` / `ort-sys` crates,
so a Rust build inside them links the chain ONNX Runtime and can never fetch
pyke's prebuilt one (G3 of the
[ONNX Runtime single-source rule](onnxruntime-single-source.md)).

| Variable | Windows (`windows/Dockerfile`, final) | Linux (`linux/Dockerfile.package`, every variant) |
|---|---|---|
| `ORT_LIB_LOCATION` | `$ONNX_ROOT\lib` (holds `onnxruntime.lib`) | `${ONNXRUNTIME_OUTPUT_DIR}/lib` = `/usr/local/lib/onnxruntime-cpu/lib` |
| `ORT_PREFER_DYNAMIC_LINK` | `1` | `1` |
| `ORT_SKIP_DOWNLOAD` | `1` | `1` |
| `ORT_DYLIB_PATH` | `$ONNX_ROOT\bin\onnxruntime.dll` | `${ONNXRUNTIME_OUTPUT_DIR}/lib/libonnxruntime.so` |

Why these four, read from `ort-sys` 2.0.0-rc.13 (the checksum OxidANT's
`Cargo.lock` pins) and `ort` 2.0.0-rc.13:
- `build/main.rs:47-68` reads `ORT_LIB_PATH`, then `ORT_LIB_LOCATION`, before the
  download branch. With `ORT_PREFER_DYNAMIC_LINK` set to `1` or `true` the build
  script emits `rustc-link-lib=onnxruntime` from that directory; without it,
  ort-sys tries a static link the chain does not ship.
- The first SET one of `CARGO_NET_OFFLINE`, `ORT_SKIP_DOWNLOAD` and `ORT_OFFLINE`
  decides, and only exactly `1` or `true` skips the download. An empty value is
  set, so an empty `CARGO_NET_OFFLINE` re-arms the download, and an empty
  `ORT_LIB_PATH` still outranks `ORT_LIB_LOCATION`.
- `ort`'s load-dynamic opens `ORT_DYLIB_PATH`, otherwise a bare file name, which on
  Windows reaches `System32\onnxruntime.dll` (Windows ML 1.17) before PATH.
- `ort`'s default features include `download-binaries`.

**What it means for a consumer.**
- An `ort-sys` build in the image links the chain import library, so a shipped
  bundle must carry the chain DLL or `.so` beside the app.
- Keep `ORT_LIB_PATH` unset and never export a falsy `CARGO_NET_OFFLINE`.
- On the Linux GPU variants the variables name the CPU chain build, which is what
  `ld.so` resolves. A GPU consumer points both at `onnxruntime-gpu/lib`, which is
  chain-built too. On `:winarm64` they name the aarch64 chain ORT.
- `ORT_DYLIB_PATH` is baked in, so inside the image a program that honours it loads
  the image's copy, not one staged beside its exe. A bundle smoke run inside the
  image should unset it to exercise the staged copy.

**How it is proven on the shipped image.** Windows: Test-Container section 19,
`Get-OrtCrateEnvFinding`, on every lane. Linux: the contract row `ort-crate-env`.
Its probe reports `ORT_LIB_PATH` and `CARGO_NET_OFFLINE` as `<unset>` when they
are not set, and the row passes only with `ORT_LIB_PATH` unset and
`CARGO_NET_OFFLINE` unset, `1` or `true`; a missing line reads as set-but-empty and
fails. Both compare values untrimmed, as ort-sys does. The static half is
`verify-critical-fixes.sh` fix11. Not covered: Rust builds outside the images, and
the live in-image `cargo build -vv` of a scratch ort-sys crate, which is still to
run at the next image build.

### The chain ONNX Runtime wheels

- **Linux:** `/opt/onnxruntime-wheels`, advertised as `ORT_CHAIN_WHEEL_DIR`, holds
  exactly the ORT and GenAI wheels `/opt/venv` was installed from.
  `setup-torch-venv.sh stage_chain_ort_wheels` proves the venv against it at build
  time. The census that proof runs ships at
  `/opt/scripts/03-media/final/ort-venv-census.py`; its command line and output
  lines are a contract that `python_uv.sh` and `setup-torch-venv.sh` read.
- **Windows:** the same wheels sit in `C:\runtime\wheels` (`PYTHON_WHEELS`). The
  census ships at `C:\temp\scripts\ort-venv-census.py`, beside the module copy whose
  `Sync-UvChainOnnxRuntime` runs it; `Build-TorchApp.ps1` embeds its own copy.
- **Who gets them:** a consumer on the hub's Python CI has its venvs reconciled onto
  them inside our images
  ([`python-ci.md` § Trap 3](python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi)).
  Anyone else calls `uv_reconcile_chain_ort <venv>` or
  `Sync-UvChainOnnxRuntime -VenvPath <venv>`.

### Prove your bundle ships the image's ONNX Runtime

Run the ORT census (G6) inside the image you built in, after staging the runtime
DLLs or `.so` files. The reference is that image's chain ORT.
- Windows: `Import-Module C:\temp\scripts\modules\WindowsOrtProvenance.Common.psm1`,
  then `if (-not (Test-OrtProvenanceTree -Root <bundle>)) { exit 1 }`. `-PassThru`
  returns the census object.
- Linux: `bash third_party/ANTfrastructure/linux/scripts/06-packaging/check-ort-provenance.sh <bundle>`.

Tree mode models a client loader. A DLL's imports resolve from the directory of
the exe that loads it, then System32 (assumed to hold Windows ML's
`onnxruntime.dll`), then PATH, never from the DLL's own directory; a `.pyd` also
searches its own directory first. So ship `onnxruntime.dll` beside the exe, not
beside a plugin. A bundle fails as STALE with an older chain DLL, FOREIGN with a
NuGet, PyPI or pyke ORT (statically linked ones included), and UNRESOLVED when an
importer has no app-local chain copy or a Linux `.so` has no `$ORIGIN` RUNPATH to
one.
