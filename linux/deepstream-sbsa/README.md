# DeepStream SBSA libraries — Linux arm64 (CON42 phase 7)

The drop point for the three Tegra libraries DeepStream's arm64 route needs:
`libnvbufsurface.so.1.0.0`, `libnvbufsurftransform.so.1.0.0` and `libnvdsbufferpool.so`.
NVIDIA's Jetson runtime `.deb` leaves them to L4T, and their SBSA builds ship only inside
NVIDIA's SBSA container (`DEEPSTREAM_SBSA_IMAGE` in `versions.env`, pinned by digest).

Stage them on the build host, by the pinned digest, with their licence:

```bash
bash linux/scripts/05-frameworks/stage-deepstream-sbsa.sh          # pulls the container, copies, verifies
bash linux/scripts/05-frameworks/stage-deepstream-sbsa.sh --check  # verifies what is staged (DEEPSTREAM_SBSA_DIR overrides the directory)
```

The media stage mounts this directory read-only and refuses any byte that is not the
pinned one. With the three files present, an nvidia chain builds DeepStream for arm64;
without them the arm64 media stage gets `ENABLE_DEEPSTREAM=false` and says why.
Everything here but this README is ignored by Git. The contract and its limits:
[`docs/linux-accelerator-images.md` § DeepStream on arm64 (SBSA)](../../docs/linux-accelerator-images.md#deepstream-on-arm64-sbsa).
