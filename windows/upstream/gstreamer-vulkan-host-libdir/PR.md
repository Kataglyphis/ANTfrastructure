# vulkan: pick the Windows SDK library dir from host_machine

| | |
|---|---|
| Target | `gstreamer/gstreamer` `main` — **GitLab MR**, <https://gitlab.freedesktop.org/gstreamer/gstreamer> |
| Base | `23616d5ccb36`, 2026-09-02 |
| Patch | [`0001-vulkan-pick-the-Windows-SDK-library-dir-from-host_ma.patch`](0001-vulkan-pick-the-Windows-SDK-library-dir-from-host_ma.patch) |
| Gates | none |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `23616d5ccb36`.
- Before: the aarch64 link fails on `vulkan-1.lib`. After: the Vulkan plugins
  link and load. Measured on 1.29.2, not on `main`.
- No open MR for it (GitLab API, `vulkan_lib_dir` / `build_machine vulkan`,
  2026-09-02).
- Only `Lib-ARM64` is added. The SDK also ships `Lib-ARM` for 32-bit ARM; that
  stays on the existing `Lib32` fallback rather than being guessed at.

## Submit

```sh
git clone https://gitlab.freedesktop.org/gstreamer/gstreamer
cd gstreamer && git checkout -b vulkan-host-machine-libdir
git am /path/to/0001-*.patch
git push -o merge_request.create
```
