# Windows Container Build Performance

Findings from making a large C++23 project build fast inside the Windows
toolchain image. Everything here was **measured**, including the approaches
that failed — the dead ends are documented deliberately so nobody spends an
afternoon rediscovering them.

Reference project: a ~690-object C++23 **modules** engine (Vulkan, CMake +
ninja + clang-cl, Rust bridged in via corrosion/cxx), built on a Dev Drive
host. Concrete script:
`Kataglyphis-BeschleunigerBallett/Scripts/Windows/Build-Windows-Container.ps1`.

## Result

| Approach | Outcome |
| --- | --- |
| **Reusable container + tar-pipe** | ✅ **9.6 s** ninja / **44 s** wall, no-change |
| Bind mount instead of the tar-pipe | ❌ 32.7 s ninja / 159 s wall — **slower**, see below |
| Streaming the build tree in and out | 🟡 ~230 s (worked, but moved ~17 GB per build) |
| sccache with a persistent named volume | ❌ 0.00 % hit rate, 0 bytes stored |
| Named volume mounted as the build directory | ❌ CMake cannot configure inside it |
| Fresh container per build (starting point) | 352–484 s |

Cold builds, for reference: 327.9 s (tar-pipe, fresh container) and 318.1 s
(bind mount). The transport barely matters cold — it is the *incremental* case
where the difference is decisive.

## What works: reuse one container

Create a **single long-lived container** instead of one per build. The build
tree never leaves it, so ninja's dependency graph, C++23 module BMIs and
object files are all still there next time.

```powershell
# reuse if running; start if stopped; recreate if the image changed
$state = docker inspect -f '{{.State.Running}}|{{.Image}}' $name 2>$null
```

- **Inbound:** stream sources only. `tar` preserves mtimes, so ninja rebuilds
  exactly what changed.
- **Outbound:** stream back only what the host needs to *run* — `*.exe`,
  `*.dll`, `*.pdb`, `compile_commands.json`, logs. Copying the whole build
  tree back is unnecessary once the container keeps its own copy.

### Safety rails this needs

Reuse trades isolation for speed, so guard it:

1. **Compare the container's image ID against the referenced image** and
   recreate on mismatch — otherwise a rebuilt toolchain image is silently
   ignored and you keep building against the old one.
2. **Provide an explicit reset switch** (`-FreshContainer`, or
   `docker rm -f <name>`). Sources are overwritten in place and never pruned,
   so a file **deleted** on the host still exists inside the container.

   This is not theoretical - measured 2026-07-19. A probe test file was added,
   built and observed to run; the file was then deleted on the host and the
   project rebuilt. **The test still ran**, and the `.cpp` was still present
   inside the container. Consequences worth internalising: tests keep passing
   against deleted code, and a deletion that breaks the build passes locally
   and fails in CI, where nothing is reused.

   If you want reuse without this hazard, prune the source tree inside the
   container before streaming (keeping the build directory and logs) rather
   than extracting over it. Sources re-stream in seconds; only the build tree
   is worth preserving. Get the exclusion pattern right first - a wrong one
   deletes the build tree on every build and silently undoes the whole
   optimisation.
3. Keep the build root: if the build script wipes its build directory before
   configuring, gate that behaviour behind an env var (this project uses
   `KATAGLYPHIS_KEEP_BUILD_ROOT`) or reuse buys nothing.
4. **Verify the artifacts exist and arrived.** A zero exit code proves neither.
   Both halves failed silently in the reference project:

   - A build was **cut off before linking**, reported success, and produced no
     test executable at all. The log simply stopped partway through the step
     count (`[982/1022]`) with no summary and no error.
   - The outbound `tar` selected files by **glob** — which `tar` does not
     expand. It copied nothing, reported success, and looked correct only
     because stale artifacts from an earlier build were already on the host.
     Select by `--exclude` instead.

   Hours went into diagnosing a "transport bug" that was really a truncated
   build, because a green build was taken as evidence that binaries existed.
   After the transfer, list the executables **inside** the container and assert
   each one reached the host; fail the build if the container produced none, or
   if any did not arrive.

   Check **existence, not timestamps**: on a no-change incremental build the
   linker does not run, so the executables are legitimately older than the
   current run. A freshness check would false-fail exactly when the cache is
   working best.

## What does not work

### A bind mount instead of the tar-pipe (on a Dev Drive)

The tar-pipe exists because Dev Drive hosts reject bind mounts. Allow-listing
the filters removes that restriction:

```powershell
fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"   # elevated; needs a reboot
```

Note the quoting — the filter list is **one argument**. `bindFlt, wcifs`
unquoted is parsed as two and fails with a syntax error. The setting persists
immediately but the filters only attach after the volume is dismounted, so
reboot (or `/f`, which force-dismounts a volume that is in use — a bad idea
for the volume holding your repo).

It works, and it is **slower**. Measured on the same tree, both transports
using the same in-container path:

| | ninja | wall |
| --- | --- | --- |
| tar-pipe + reused container, no-change | **9.6 s** | **44 s** |
| bind mount, no-change | 32.7 s | 159 s |

Removing the transport does not pay for what it adds. With a bind mount the
build tree lives on the Dev Drive, so every ninja stat and every object write
crosses the `bindFlt` filter from inside the container. Copying sources in
bulk once is cheaper than paying filtered I/O across ~1000 targets — ninja
alone tripled on an identical tree. Repeated to rule out a first-run artifact.

There is a second cost: a Dev Drive is fast precisely *because* filters do not
attach to it. Allow-listing them slows general I/O on that volume, not just
container builds. `fsutil devdrv clearFiltersAllowed /volume D:` reverts it.

**Do not assume this generalises.** On a normal (non-Dev-Drive) volume, or
with a much smaller build tree, the transport can dominate and the bind mount
can win. Measure before choosing; keep both paths behind a switch.

### Mount both transports at the SAME in-container path

If you support both, mount at the path the tar-pipe already uses. CMake bakes
absolute paths into `CMakeCache.txt` and refuses to reuse a cache generated
elsewhere:

```
CMake Error: The source "C:/ws-mnt/CMakeLists.txt" does not match
the source "C:/ws/CMakeLists.txt" used to generate cache.
```

Switching transports then forces a cold rebuild every time. One shared path
(here `C:\ws`) keeps the trees interchangeable. The path must still be absent
from the image — mounting over a directory baked in (`C:\workspace`) fails at
`CreateComputeSystem` when the host OS build differs from the image base.

### sccache on a C++23 modules build

`sccache` runs, reports the right cache location, and caches **nothing**:

```
Compile requests            907
Cache hits rate            0.00 %
Cache misses                780
Cache size                    0 bytes
```

Zero stored bytes on a byte-identical tree. Module compilations depend on
BMIs that sccache cannot hash reliably, so results are never stored. A
persistent volume for the cache directory is therefore pointless here —
harmless to leave wired up, but do not expect a speedup. **On non-module
codebases sccache is still worth using**; this finding is specific to C++20/23
modules.

### A named volume as the build directory

Mounting a Docker named volume at the build directory looks like the natural
fix. CMake cannot configure inside one:

```
CMakeTestCXXCompiler.cmake:71 (message)
  ninja: error: loading 'build.ninja': The system cannot find the file specified.
```

Reproduces with a **freshly created** volume, so it is not stale state.
Windows container volumes are filter-driver backed and do not behave like an
ordinary directory for the operations CMake's compiler test performs.

## Gotchas that cost real time

- **Windows path limit inside containers.** Deeply nested paths (here: Rust
  `cxxbridge` output under `cargo/`) fail to extract:

  ```
  ...out/cxxbridge/include/.../native_only.rs:
    Can't create '\\?\C:\ws\...': Invalid argument
  tar: Error exit delayed from previous errors
  ```

  **One such failure aborts the entire tar transfer**, so a single deep path
  silently turns a full transfer into a partial one. Exclude those subtrees.

- **Dev Drive rejects bind mounts.** The filesystem minifilter cannot attach
  ("Der Dateisystem-Minifilter kann nicht an das Entwicklervolume angefügt
  werden"), which forces the tar-pipe transport in the first place. Allow-
  listing the filters lifts the restriction — but measured slower here; see
  "What does not work" above before reaching for it.

- **Containers survive successful builds** (`wcifs` teardown lock). A
  lingering container makes it look like a build is still running. Compare the
  newest build-summary timestamp against the container start time before
  assuming, and reap stale containers by name.

- **`docker exec` bypasses the image entrypoint.** When driving a long-lived
  container with `docker exec` (rather than `docker run`), the entrypoint that
  sets up the VS developer environment and the clang-cl ASAN runtime DLL
  directory never runs. Invoke it explicitly:

  ```powershell
  docker exec -w C:\ws $container cmd /S /C C:	emp\scripts\entrypoint.cmd @buildArgs
  ```

  Symptoms if you forget: compilers "not found", or ASAN binaries failing to
  start because `clang_rt.asan*.dll` is not on `PATH`.

- **Mount over a fresh path.** Mounting onto a directory baked into the image
  (e.g. `C:\workspace`) fails at `CreateComputeSystem` when the host OS build
  differs from the image base build. Use a new path such as `C:\ws-mnt`.

## Reusable implementation

The pattern is implemented here so consumers do not copy it:
`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1`
(`Get-ReusableBuildContainer`, `Copy-IntoBuildContainer`,
`Copy-FromBuildContainer`). Import it via the consumer's module resolver.

## Applying this elsewhere

The pattern generalises to any large project built in a Windows container:

1. One reusable container, keyed by name, recreated when the image changes.
2. Sources in, artifacts out — never the intermediate build tree.
3. An explicit "start clean" switch, because reuse means staleness.
4. Exclude deep paths from tar transfers before they abort silently.
