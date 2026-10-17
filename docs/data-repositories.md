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

**History is not rewritten.** A rewrite changes every commit id that releases and other
repositories pin (OxidANT's decision D4). The old blobs stay in the history, and a CI checkout
that wants less can clone with `filter: blob:none`.

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

Every fetcher keeps the same contract:

- It downloads through a cache keyed by the hash: `KATAGLYPHIS_MODEL_CACHE` or
  `KATAGLYPHIS_ASSET_CACHE`, else `%LOCALAPPDATA%` or `~/.cache`.
- It checks the hash of the cached copy and of every download. A model fetcher re-hashes the
  target too, and the scene fetcher reads its stamp (below).
- It writes atomically (`.part`, then rename) and retries a failed download three times.
- The scene fetcher never overwrites what it did not write: a scene directory without its
  stamp stops the configure.

| Consumer | Lock | Fetcher |
| --- | --- | --- |
| OxidANT | `resources/models/models.lock` | `scripts/linux/fetch-models.sh`; OmniAccelerANT's `scripts/windows/Get-Models.ps1` |
| OrchestrANT | `resources/models/models.lock` | `scripts/fetch_models.py` (stdlib, Linux and Windows) |
| BeschleunigerBallett | `Resources/assets.lock` | `cmake/FetchAssets.cmake`, at every configure or as `cmake -P` |

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

Three fetchers keep one contract in three languages; one hub-owned implementation is
BACKLOG CON98.
