# gst-plugins-base: gate have_sse/have_sse2 on cpu_family

| | |
|---|---|
| Target | `gstreamer/gstreamer` `main` — **GitLab MR**, <https://gitlab.freedesktop.org/gstreamer/gstreamer> (the GitHub repo is a mirror) |
| Base | `23616d5ccb36`, 2026-09-02 |
| Patch | [`0001-gst-plugins-base-gate-have_sse-have_sse2-on-cpu_fami.patch`](0001-gst-plugins-base-gate-have_sse-have_sse2-on-cpu_fami.patch) |
| Gates | none (no CLA, no DCO) |

The commit message is the description. Nothing to add.

## Checked

- Applies clean at `23616d5ccb36`.
- Hit and fixed on our aarch64 cross lane (GStreamer 1.29.2, clang-cl 23.1.0).
  Not rebuilt against `main`.
- No open MR for it (GitLab API, `have_sse` / `cpu_family sse`, 2026-09-02).
- The GNU branch is a no-op in practice — `cc.has_argument('-msse')` is already
  false on aarch64 — but `have_sse41` is guarded in both branches, so this
  follows suit. Say so if you would rather it only touched the msvc branch.

## Submit

```sh
git clone https://gitlab.freedesktop.org/gstreamer/gstreamer
cd gstreamer && git checkout -b sse-cpu-family-gate
git am /path/to/0001-*.patch
git push -o merge_request.create
```
