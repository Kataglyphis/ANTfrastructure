# Windows Container Build Performance

Findings from making a large C++23 project build fast inside the Windows
toolchain image. Everything here was **measured**, including the approaches
that failed — the dead ends are documented deliberately so nobody spends an
afternoon rediscovering them.

Reference project: a ~690-object C++23 **modules** engine (Vulkan, CMake +
ninja + clang-cl, Rust bridged in via corrosion/cxx), built on a Dev Drive
host. Concrete script:
`BeschleunigerBallett/scripts/windows/Build-Windows-Container.ps1`.

## Result

| Approach | Outcome |
| --- | --- |
| **Reusable container + tar-pipe** | ✅ **9.6 s** ninja / **44 s** wall, no-change |
| Reusable container + bind mount | ✅ works; 32.7 s ninja / 159 s wall — slower *here* |
| Streaming the build tree in and out | 🟡 ~230 s (worked, but moved ~17 GB per build) |
| sccache with a persistent named volume | ❌ 0.00 % hit rate, 0 bytes stored |
| Named volume mounted as the build directory | ❌ CMake cannot configure inside it |
| Fresh container per build (starting point) | 352–484 s |

Cold builds, for reference: 327.9 s (tar-pipe, fresh container) and 318.1 s
(bind mount). The transport barely matters cold — it is the *incremental* case
where the difference is decisive.

## Transports: how to set up both

Getting sources into the container and artifacts back out has two working
implementations. **Both are supported and worth keeping** — which one wins
depends on the host, and the answer here was the opposite of what we expected.
Keep them behind a switch and measure rather than assume.

### Which one should I use?

| | tar-pipe | bind mount |
| --- | --- | --- |
| Host setup needed | none | elevated `fsutil` + reboot (Dev Drive only) |
| Where the build tree lives | inside the container | on the host volume |
| Incremental cost | copies sources each build (~35 s here) | none |
| Per-file I/O cost | container-local, fast | crosses the filter, slow |
| **Measured here (no-change)** | **9.6 s ninja / 44 s wall** | 32.7 s ninja / 159 s wall |
| Survives `docker rm` | ❌ tree is lost | ✅ tree is on the host |

Rules of thumb:

- **Large build tree, incremental edit-build loop → tar-pipe.** You pay a
  fixed bulk copy once per build instead of filtered I/O on every one of
  ~1000 targets. This is why it wins on the reference project.
- **Small tree, or a host where the transport dominates → bind mount.** The
  fixed copy cost stops being amortised and removing it wins.
- **Non-Dev-Drive volume → measure again.** The penalty below is specific to
  a Dev Drive with filters allow-listed; an ordinary NTFS volume does not
  behave the same way.
- **You want the build tree to survive the container → bind mount.**

### Transport A — tar-pipe (no host setup)

Works everywhere, including Dev Drive hosts with default settings, because it
never asks the filesystem to attach anything.

```pwsh
# in:  sources only, excluding .git and build trees
tar -cf - --exclude .git -C $repoRoot . | docker exec -i $c tar -xf - -C C:\ws
# out: only what the host runs, selected by EXCLUSION (tar does not expand globs)
docker exec $c tar -cf - --exclude "*/CMakeFiles" --exclude "*.obj" -C C:\ws build-x | tar -xf - -C $repoRoot
```

Requirements: none. Caveats: the deletion hazard (safety rail 2 below), and
`tar` aborting a whole transfer on one over-long path (see Gotchas).

### Transport B — bind mount (Dev Drive needs setup)

A Dev Drive refuses bind mounts by default — the minifilter cannot attach
("Der Dateisystem-Minifilter kann nicht an das Entwicklervolume angefügt
werden"). Allow-list the two filters, **elevated**:

```pwsh
fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"
```

Four things that cost time here:

1. **The filter list is ONE quoted argument.** `bindFlt, wcifs` unquoted is
   parsed as two arguments and fails with a bare syntax dump.
2. **It needs a reboot.** The setting persists immediately, but the filters
   only attach when the volume is dismounted. You will see
   `Fehler 5: Zugriff verweigert` — that is the *dismount* failing because the
   volume is in use, not the setting failing. `/f` force-dismounts instead;
   do not use it on the volume holding your repo.
3. **`query` shows "allowed" before "attached".** After the reboot the filters
   are listed as allowed but still not attached — they attach *on demand*, the
   first time something actually requests a bind mount. Do not read that as
   failure; probe instead.
4. **Omitting `/volume` sets it machine-wide.** Scope it to the volume you
   mean.

Verify — allow-list, then an actual mount:

```pwsh
fsutil devdrv query D:        # expect: bindFlt, wcifs under "allowed"
docker run --rm --isolation process `
  --mount "type=bind,source=$repoRoot,target=C:\ws" `
  --entrypoint cmd $image /c "dir C:\ws\CMakePresets.json"
```

Revert (a Dev Drive is fast *because* filters do not attach — allow-listing
them slows general I/O on that volume, not just container builds):

```pwsh
fsutil devdrv clearFiltersAllowed /volume D:   # + reboot
```

#### Mount both transports at the SAME in-container path

If you support both — and you should — mount at the path the tar-pipe already
uses. CMake bakes absolute paths into `CMakeCache.txt` and refuses to reuse a
cache generated elsewhere:

```
CMake Error: The source "C:/ws-mnt/CMakeLists.txt" does not match
the source "C:/ws/CMakeLists.txt" used to generate cache.
```

Without a shared path, every switch between transports forces a cold rebuild
and the two are not really interchangeable. One path (here `C:\ws`) fixes it.

The path must still be **absent from the image**: mounting over a directory
baked in (`C:\workspace`) fails at `CreateComputeSystem` when the host OS build
differs from the image base build. Verify with
`docker run --rm --entrypoint cmd $image /c "if exist C:\ws (echo BAKED IN)"`.

#### Why the bind mount lost here

With a bind mount the build tree lives on the Dev Drive, so every ninja stat
and every object write crosses the `bindFlt` filter from inside the container.
Copying sources in bulk once is cheaper than paying filtered I/O across ~1000
targets — **ninja alone tripled**, 9.6 s → 32.7 s on an identical tree.
Repeated to rule out a first-run artifact.

Cold builds are near-identical (327.9 s vs 318.1 s), which is the tell: the
penalty is per-file-operation, not per-byte, so it only shows up once
compilation stops dominating.

## What works: reuse one container

Create a **single long-lived container** instead of one per build. The build
tree never leaves it, so ninja's dependency graph, C++23 module BMIs and
object files are all still there next time.

```pwsh
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

## The image does not fit on C:, and that is the default

On a GitHub-hosted `windows-2025` runner, Docker keeps its data-root under the
**system** drive (`C:\ProgramData\Docker`). That drive is the small one.
Measured 2026-08-11 at job start:

```
DriveLetter FreeGB SizeGB FileSystemLabel
          C  33.00 149.40 Windows
          D 146.60 150.00 Temporary Storage
```

The `winamd64` image needs **~54 GB** to import. It does not fit in 33 GB, and
the failure is expensive rather than obvious: `docker pull` grinds for tens of
minutes and then dies with `hcsshim::ImportLayer ... not enough space on the
disk (0x70)`.

The historical workaround was `cleanup-disk-space`, which deletes Visual Studio
and the tool caches to claw C: up to ~71 GB. That works, costs minutes, is
destructive — and leaves a 150 GB drive sitting at 146.6 GB free.

**Point the data-root at the big drive instead**, with the
[`set-docker-data-root`](../.github/actions/README.md) action, *before* the pull:

```yaml
- name: 'Put the Docker data-root on D:'
  uses: Kataglyphis/ContainerHub/.github/actions/set-docker-data-root@main
  with:
    data-root: 'D:\docker'
```

Measured on the same job, across the whole run:

| Point in the job | C: free | D: free |
|---|---|---|
| start | 33.00 | 146.60 |
| after the data-root move | 33.00 | 146.60 |
| after `cleanup-disk-space` | 71.20 | 146.60 |
| **after `docker pull`** | **71.20** | **108.10** |

D: absorbs **38.5 GB**; C: does not move at all, even though 71 GB were free
there by then. The daemon confirms it independently: `Docker data-root: D:\docker`.

Things worth knowing before you copy this:

- **Order is not negotiable.** Run it before the pull. Changing the data-root
  makes images under the old one invisible, so doing it afterwards throws away
  a pull you already paid for.
- **It merges into an existing `daemon.json`.** The runners ship one — on the
  measured job it contained `{"hosts":["npipe://"]}`. Overwriting that would
  have taken the daemon's named-pipe listener with it.
- **D: is not the same size everywhere.** Two runners on the same day reported
  150 GB and 220 GB. The action's `required-free-gb` checks the *target* drive
  rather than assuming, so a wrong drive letter fails in seconds with a clear
  message instead of during the import.
- **D: is the ephemeral temp disk on hosted runners** — wiped between jobs,
  which is right for CI and wrong for a self-hosted machine you expect to keep
  a layer cache on. Point `data-root` somewhere persistent there.
- **`cleanup-disk-space` still earns its place** — checkout, toolchain and build
  live on C: — but it is no longer what makes the image fit.

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

  ```pwsh
  docker exec -w C:\ws $container cmd /S /C C:	emp\scripts\entrypoint.cmd @buildArgs
  ```

  Symptoms if you forget: compilers "not found", or ASAN binaries failing to
  start because `clang_rt.asan*.dll` is not on `PATH`.

- **Mount over a fresh path.** Mounting onto a directory baked into the image
  (e.g. `C:\workspace`) fails at `CreateComputeSystem` when the host OS build
  differs from the image base build. Use a path absent from the image — and if
  you support both transports, make it the *same* path the tar-pipe extracts
  to (`C:\ws`), not a separate one, or CMake rejects the cache on every switch.
  See [Transports](#transports-how-to-set-up-both).

## Reusable implementation

The pattern is implemented here so consumers do not copy it:
`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1`
(`Get-ReusableBuildContainer`, `Copy-IntoBuildContainer`,
`Copy-FromBuildContainer`, `Initialize-ContainerPwsh`,
`Remove-StaleContainerSources`, `Test-BuildArtifactsDelivered`,
`Remove-BuildContainerSafe`, `Wait-ContainerExit`). Import it via the
consumer's module
resolver. `Initialize-ContainerPwsh`, `Remove-StaleContainerSources` and
`Test-BuildArtifactsDelivered` are the safety rails of the
reusable-container pattern as functions: ensure pwsh exists in the image,
prune stale sources on reuse (tar never deletes), and verify every built
executable actually reached the host before trusting a green build.
`Remove-BuildContainerSafe` removes a container while tolerating the wcifs
teardown lock.

`Wait-ContainerExit` is the fourth rail, and it points the other way: the
docker CLI intermittently drops its pipe mid-run on this host while the
container keeps building, so a non-zero *client* exit can be a failure that
did not happen. It polls `{{.State.Status}}` until the container is no longer
running and returns `{{.State.ExitCode}}` — the container's verdict, not the
client's — with a bounded timeout and a named error for every way the wait can
go wrong (vanished container, unreachable daemon, a container that never
started, a state it does not recognise — unknown or empty states fail CLOSED
rather than being read as "finished"). It requires a run that is **named and
not `--rm`**: with `--rm` the daemon removes the container the instant it
exits, taking the exit code with it. That is why the bind-mount transport
names its run and removes it itself — but only on success. Every failure
thrown out of the run/wait block points the operator at
`docker logs <name>-bindmount`, so a failed or timed-out run KEEPS its
container (a warning says so, with the removal command); deleting it in a
`finally` would destroy the evidence the error message just promised.

The pre-removal before the run has two refusals, both there to stop a false
green. A leftover under the name that is still *running* (a concurrent build
of the same tree, or a runaway a timed-out wait kept) is never force-removed —
the build throws instead. And when `docker rm -f` is blocked by the wcifs
teardown lock (the removal returns but the container survives), the run falls
back to a unique `<name>-bindmount-<6 hex>` name, exactly like
`Get-ReusableBuildContainer -Fresh` does: running against the held name would
make `docker run` fail 125 with a name conflict, and the wait would then read
the STALE container's exit code — a build that never ran, reported green.

One layer down, `Wait-ContainerExit`'s inspect helper takes its value ONLY
from stdout: docker prints client notices (deprecations, context warnings) on
stderr *before* the field value, so a first-line pick over a merged stream
returns the notice as the "value" — a clean container read as a non-numeric
exit code, or a still-running one as finished. stderr is kept separately for
classifying failures (missing container vs unreachable daemon).

A red client exit gets one extra `docker inspect` to distinguish "docker run
failed before any container existed" (unresolvable image, refused mount — the
client's code is the whole story, nothing to wait on) from a dropped pipe. That
probe runs ONLY on the failure path: after a clean run the container exists by
definition, and the happy path must not grow a docker call — the no-change
build is 44 s wall, and every client round-trip on this host costs seconds.

`Wait-ContainerExit` does **not** apply to the reusable container's `docker
exec` builds — that container's main process is a 7-day `ping`, so its state
is `running` no matter what the build did.

## Applying this elsewhere

The pattern generalises to any large project built in a Windows container:

1. One reusable container, keyed by name, recreated when the image changes.
2. Sources in, artifacts out — never the intermediate build tree.
3. An explicit "start clean" switch, because reuse means staleness.
4. Exclude deep paths from tar transfers before they abort silently.
