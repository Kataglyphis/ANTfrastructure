<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Data repositories: models and scenes outside the code

**Code repositories track code** (owner, 2026-10-17). Trained weights live in
[ModelANT](https://github.com/Kataglyphis/ModelANT), 3D scenes in
[AssetANT](https://github.com/Kataglyphis/AssetANT). A consumer pins each file by SHA-256 in a
lock and fetches it by checksum, so a clone carries no data, every file has one traceable
license, and swapping a model or a scene moves one lock line.

## What moved, and why

| Consumer | What left the tree | Why it mattered |
| --- | --- | --- |
| OxidANT, OmniAccelerANT | YOLO26/YOLOv10 (2026-10-14) | AGPL-3.0 weights in MIT and Apache repositories |
| OrchestrANT | `yolov26m.onnx`, 78 MiB (2026-10-17) | the same AGPL weights, shipped in every package |
| BeschleunigerBallett | 14 scenes, 518 of 633 MiB at HEAD (2026-10-17) | the code loads two of them, the packages install one |

**The history was rewritten on 2026-10-17** (owner, superseding OxidANT's decision D4): every
binary blob of 500 KB or more that no branch held left the history of all ten family
repositories, so AssetANT's and ModelANT's releases are the data's only copies. Every commit was
kept, so each old id maps to one new one, and the gitlinks moved with them. The ten packs went
from about 1.9 GiB to 0.35 GiB (BeschleunigerBallett 1.24 GiB to 146 MiB, OmniAccelerANT
167 to 12 MiB, this hub 161 to 20 MiB). The history from before is kept offline in one git
bundle per repository; GitHub serves its old objects until its own garbage collection.

## A data repository

- **One directory per item** with its metadata: `models/<name>/model.json`,
  `assets/<name>/asset.json`. It records the upstream source, the license and how the license
  was established. AssetANT says `unknown` where nothing was found rather than guessing.
- **Scripts that rebuild the release bytes.** ModelANT exports from a pinned upstream commit
  and checkpoint. AssetANT packs reproducibly: sorted entries, mtime 0, owner 0, `xz -9 -T1`.
  Debian 13 and Ubuntu 26.04 packed three of its assets to the same hashes.
- **One release per item version**, tag `<name>-v<N>`: the files, the metadata and
  `SHA256SUMS`. A consumer's lock then moves one line when one item changes.
- **Immutable releases are on** in both repositories (2026-10-17), so a published file can
  never be replaced. A changed item is `<name>-v<N+1>`.
- **The credit travels with the files**: a model's `LICENSE` and `NOTICE` are release files
  that packages ship beside it, and every AssetANT archive carries `ATTRIBUTION.txt`.

## The lock

One line per file, `#` for comments, whitespace-separated:

```text
# sha256                                                          file                    url
225f612fc879d604b79a569648f274672090070a07dcbdef469796df956f8392  deim_dfine_n_coco.onnx  https://github.com/Kataglyphis/ModelANT/releases/download/deim_dfine_n_coco-v1/deim_dfine_n_coco.onnx
```

## The hub's fetcher

`linux/scripts/lib/fetch-data-lock.py --lock FILE [--dest DIR] [--extract] [--only NAME]...
[--cache DIR]` is stdlib Python, so every lane on both systems runs the same code;
`cmake/KataglyphisFetchData.cmake`'s `kataglyphis_fetch_data(LOCK <file> [DEST <dir>] [EXTRACT]
[ONLY <name>...])` runs it at configure or in `cmake -P`, and stops on any failure.

- **The cache is keyed by the hash**: `<sha256>-<file>` in `--cache`, else
  `KATAGLYPHIS_MODEL_CACHE` (`KATAGLYPHIS_ASSET_CACHE` with `--extract`), else
  `kataglyphis-models` or `kataglyphis-assets` under `%LOCALAPPDATA%` or `~/.cache`. A bare
  `<sha256>` entry, as the first model fetchers wrote it, still serves.
- **Every cached copy, every download and every target is hashed**; a mismatch fails and leaves
  neither the target nor a part behind, and so does a refused rename (a Windows bind mount
  answered one with `WinError 3`). An http(s) download gets three attempts; a failed one
  names the cache path an offline copy goes to.
- **It writes by one rename**, a file `0644` whatever the umask, and one fetch holds a cache at a
  time (`<cache>/.lock`). It exits 1 on a failed fetch and 2 on bad arguments.
- **`--extract`** takes each file as `<name>.tar.xz` (or `.tar.gz`, `.tgz`) that unpacks to
  `<name>/` and nothing else. The scene lands with its stamp by one rename, its files touched to
  now, since archives are packed with mtime 0. A scene directory without a stamp stops the fetch:
  it never overwrites what it did not write.

`tests/test-fetch-data-lock.sh` and the `data-lock.*` mutations prove it. Read in `:latest` on
2026-10-19 over the real locks: OxidANT's `fetch-models.sh` and OrchestrANT's `fetch_models.py`
wrote the same three files, `0644`, as the hub's fetcher, and BeschleunigerBallett's
`FetchAssets.cmake` the same 44 scene files and stamps, which the hub's fetcher then read as up
to date.

| Consumer | Lock | Fetcher today | Onto the hub's |
| --- | --- | --- | --- |
| OxidANT | `resources/models/models.lock` | `scripts/linux/fetch-models.sh`; `scripts/windows/Get-Models.ps1`, which keeps no cache | both become a call of `fetch-data-lock.py --lock resources/models/models.lock` |
| OmniAccelerANT | OxidANT's | OxidANT's two, from `bundle-runtime-closure.sh`, `ci/lane-native-linux.sh`, `observant/package-observant.sh` and `Package-ObservANT.ps1` | no change past OxidANT's |
| OrchestrANT | `resources/models/models.lock` | `scripts/fetch_models.py`, from `ci_packaging.sh` and both Windows build scripts | the same call; `tests/unit/test_fetch_models.py` goes with it |
| BeschleunigerBallett | `Resources/assets.lock` | `cmake/FetchAssets.cmake`, at every configure or as `cmake -P` | `kataglyphis_fetch_data(LOCK Resources/assets.lock DEST Resources/Models EXTRACT ONLY crytek-sponza Dinosaurs)` |
| AccelerANTgine | none | `curl` and `sha256sum` by hand, in `models/README.md` | a lock and the call |

**A fetched scene directory holds a stamp with two fields**: the archive's hash and the number
of files it extracted. A matching hash alone is not enough. On 2026-10-17 a rebase deleted the
tracked scene files and kept the ignored stamp, and a hash-only check reported "up to date"
over an empty directory. Checking out a commit that still tracked the scenes does the same.

**A package fetches before it bundles.** OrchestrANT's `ci_packaging.sh` and both Windows
build scripts run the fetcher before the hub copies `packaging/app.json`'s `data`. BeschleunigerBallett's
configure fetches before the install rules run.

## What stays in a code repository

- Test fixtures a suite reads, small and next to it: OxidANT's `two_cats.jpg` (83 KiB) and
  BeschleunigerBallett's `GltfTest`, `ShadowTest` and `VikingRoom`. Tests must run offline.
- Icons, branding and a README's images, compressed: OxidANT's hero image went from a 7.5 MiB
  GIF to a 2.1 MiB WebP on 2026-10-17.
- Shaders, which are code, and a website's own content (ANThology's images and fonts).

The consumers move onto the hub's fetcher in BACKLOG CON98.

## Keeping data out of the code repositories

A file in git stays in every clone's history even after it is deleted, so the rule is
enforced at the commit that adds it. The `large-files` gate
(`linux/scripts/verify_large_files.py`) fails on any tracked data file over 500 KiB that
`large-files.allow` does not freeze: a file with a NUL byte in its first 8000 bytes (git's
own binary test), or a document, media, model, scene or archive format whatever its bytes,
because a PDF can open without a NUL and `.obj`/`.gltf` scenes are text. Lockfiles and
generated source are text and pass. `third_party/` is graded by its own repository.

- **Where it runs**: the hub's preflight and pre-commit hook, and every consumer's
  `run-lint-gates.sh --ratchets`, against `<consumer root>/large-files.allow`.
- **The freeze** is `<path> | <KiB> | <reason>`, one row per file the repo must track (a
  runtime the app loads, a document the site serves that has no other home). The size is the
  blob's as git stores it, so a `core.autocrlf` checkout reads the same as Linux. A frozen file
  that grows, shrinks, moves or goes fails until its row is updated: each new version is
  another copy in history, so it should be a conscious edit.
- **Everything else** moves to ModelANT or AssetANT and is fetched by lock, as above. A
  history that already holds such files is cleaned by a rewrite, and existing checkouts
  follow with `git-adopt-rewritten-history.sh`
  ([adopting-in-a-new-project.md § *After a history rewrite*](adopting-in-a-new-project.md#after-a-history-rewrite)).
