# mediafoundation: only detect winapi_app with msvc

| | |
|---|---|
| Target | `gstreamer/gstreamer` `main` — **GitLab MR**, <https://gitlab.freedesktop.org/gstreamer/gstreamer> |
| Base | `23616d5ccb36`, 2026-09-02 |
| Patch | [`0001-mediafoundation-only-detect-winapi_app-with-msvc.patch`](0001-mediafoundation-only-detect-winapi_app-with-msvc.patch) |
| Gates | none |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `23616d5ccb36`.
- With clang-cl on 1.29.2: `-Dgst-plugins-bad:mediafoundation=enabled` fails at
  configure before the change, and the desktop plugin builds after it.
- No open MR for it (GitLab API, `mediafoundation winapi_app` / `winapi_app msvc`,
  2026-09-02).
- MinGW hits the same asymmetry by inspection, but was not tested.

## Submit

```sh
git clone https://gitlab.freedesktop.org/gstreamer/gstreamer
cd gstreamer && git checkout -b mediafoundation-msvc-gate
git am /path/to/0001-*.patch
git push -o merge_request.create
```
