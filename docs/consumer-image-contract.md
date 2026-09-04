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
so the table cannot rot in place. Today it holds exactly two arms, both
`riscv64`, both about Flutter — upstream publishes no riscv64 SDK, `/opt/flutter`
ships empty there, and `check_flutter` asserts that absence instead. The rot
signal is the probe's own `FACT flutter-sdk`: the day a riscv64 SDK lands, both
arms fail and name themselves for deletion.

The Android SDK is **not** exempt anywhere. `/opt/android-sdk/platform-tools`
was measured present in all three shipped arches on 2026-09-04, and the parity
table already asserts the `android-sdk` prefix on every arch.

## Two things worth knowing before you configure a lane

- `:latest-cross` is a proper multi-arch index. An arm64 runner gets arm64
  binaries; there is no longer any reason to pin `-amd64` and no `rustc: 1: ELF:
  not found` to work around.
- **The image ships Flutter at `/opt/flutter`.** A lane still passing
  `--flutter-dir /workspace/flutter` re-downloads the whole SDK every run for
  nothing. `sccache` and `appimagetool` are on `PATH` as well.
