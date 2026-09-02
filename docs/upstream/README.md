# Prepared upstream submissions

**Nothing here has been posted. Do not post anything without the owner saying so.**

`../upstreamable-patches.md` is the register: every local third-party change,
graded, with the message to send where one is ready. This directory holds the
artefacts that are too big to inline there.

## Contents

| file | what it is |
| --- | --- |
| `patches/opencv-700cd32ffd.patch` | upstream OpenCV commit, `cap_ffmpeg_hw.hpp`, *support FFmpeg after AVCodec::pix_fmts removal* |
| `patches/opencv-83ed22ca28.patch` | upstream OpenCV commit, `cap_ffmpeg_impl.hpp`, *use avcodec_get_supported_config for framerates* |
| `hcsshim-lost-shutdown-notification-issue.md` | Windows lane, unrelated to the Linux register |

Both OpenCV patches are the **original upstream commits with their authorship
intact**, fetched from `github.com/opencv/opencv`. They are here because the
OpenCV submission is a *port to 5.x*, not a fix of our own: send these, not our
`002-ffmpeg8-avcodec-config-api.patch`.

Verified 2026-09-02 against `opencv/5.x`:

- both apply with **no conflicts**
- after applying them our own patch no longer applies at all, i.e. upstream
  covers the same code
- the `c->pix_fmts` and `codec->supported_framerates` uses that remain in the
  ported files all sit in the pre-FFmpeg-8 `#else` branch, so the coverage is
  complete

## Reproducing that check

```sh
mkdir -p /tmp/cvport/modules/videoio/src && cd /tmp/cvport
for f in cap_ffmpeg_hw.hpp cap_ffmpeg_impl.hpp; do
  curl -fsSL "https://raw.githubusercontent.com/opencv/opencv/5.x/modules/videoio/src/$f" \
    -o "modules/videoio/src/$f"
done
git init -q . && git add -A && git commit -qm base
git apply --check <repo>/docs/upstream/patches/opencv-700cd32ffd.patch
git apply --check <repo>/docs/upstream/patches/opencv-83ed22ca28.patch
```
