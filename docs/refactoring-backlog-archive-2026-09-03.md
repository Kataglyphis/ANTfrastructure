<!-- Closed Linux refactor items, archived 2026-09-03. OPEN work lives in refactoring-backlog.md. -->

# Refactoring backlog archive — 2026-09-03

Closed on or before 2026-09-03 and moved out of
[`refactoring-backlog.md`](refactoring-backlog.md), which is OPEN-only.
Each entry keeps the evidence that closed it.

### A1. GEN1 — riscv64 GenAI: CLOSED 2026-09-03 [★★]

Both open questions are measured. Evidence and repro:
`docs/gen1-riscv64-genai.md#tier-4-measured-2026-09-03`.

**Token sanity — the one a build could not answer — is ANSWERED, and the result
is stronger than "sane tokens":** with SmolLM2-135M-Instruct converted to GenAI
format on amd64 and mounted into both shipped images, riscv64 greedy decoding is
**token-for-token identical to the amd64 control** (first 8 ids
`28, 198, 198, 57, 5248, 18948, 346, 2316` on both; `GENAI-BIND OK` rc=0 on
both; riscv64 native ext `e_machine=243`). A kernel wrong enough to matter would
have to be wrong *identically* on two unrelated backends. **#594 does not
reproduce on this lane.**

Two traps the run walked into, both now written up so the next person skips them:
* `hf-internal-testing/tiny-random-LlamaForCausalLM` cannot be the fixture —
  `head_size=4` and GroupQueryAttention needs `% 8 == 0`; it fails on amd64 too.
* An **untrained** model is worse than useless here: near-uniform logits make
  greedy decoding repeat one token, i.e. it manufactures the exact `#594`
  signature tier 4 flags as a DEFECT. Use a really-trained small model, and run
  the **amd64 control first** — that is what identified the fixture, not the
  lane, as the broken part the first time.

The two cheap items are settled too:
* **app-wheel floor** raised riscv64 12 → **13** (the run printed 14; one wheel
  of slack is deliberate). arm64 printed 15 but is **held at 14** — one sample,
  and 15 would be a zero-slack floor. Table + the rule for raising them:
  `docs/gen1-riscv64-genai.md#the-app-wheel-floor`.
* **`validate-media-runtime.sh` genai NEEDED scan** has now run against real
  images on **all three** arches (2026-09-03 chain; the "never run on any arch"
  note was already stale when written). It resolved only `libXv.so.1` and
  `libwebpdemux.so.2` — nothing genai — and an independent `ldd` over the
  shipped riscv64 `/usr/local/lib/onnxruntime-genai/lib` reports **0 unresolved
  NEEDED**.

**Residual, deliberately left open:** tier 4 ran under **qemu-user**, which
emulates the ISA but not a physical core's timing, errata or extension set.
#594's hardware was a XuanTie C910. Re-run tier 4 on real riscv64 silicon when
any is available — the repro recipe in the doc is a copy-paste.

### A2. QNN-LINUX — CLOSED 2026-09-03: fan-out validated on a real SDK

All three questions this entry was opened to answer are answered. Evidence and
the lane's documentation live in [`qnn-linux.md`](qnn-linux.md); do not restate
them here.

| question | verdict |
|---|---|
| does ORT stay green with a real SDK staged? | **YES** |
| do the staged libs land / wheel staging? | **YES** — 45 `libQnn*.so`, into three install roots |
| does LiteRT stay green? | **YES, after a fix** — the run found a real defect |

The SDK was already on this machine and its SHA256 matched the populated
`QNN_SDK_LINUX_ZIP_SHA256` pin, so **no re-pin was needed** — as predicted. It
was staged as a hardlink (0 extra bytes) and removed again afterwards per the
`linux/qnn-sdk/README.md` discipline.

**The validation earned its keep on the first run:** LiteRT died ~7 min in with
`QnnLog.h: No such file or directory`, because `QAIRT_HEADERS_DIR` was passed one
directory too high on a belief the code stated in its own comment and which is
false for our code path. Fixed in `82b09447` (`_litert_qairt_include_dir`,
covering the configure path AND the wheel path, with an assert), guarded by
`tests/test-litert-qairt-headers.sh` and two mutation-manifest entries that were
confirmed to bite. The re-run finished `Cross chain complete.` — 60 stages, 0
fatal errors, `Qualcomm dispatch ON (… /include/QNN)`.

**Follow-up, not part of A2:** the same unhashed-QAIRT defect is still live in
the android lane — backlog **YA**.

### WA. Per-arch MEDIA_SKIP flag files are COPY'd into the shared media `base` stage, so a riscv64-only edit re-runs the whole amd64 and arm64 media stage [high]

`linux/Dockerfile.media:174`

**FIXED 2026-09-03.** The three COPYs are one parameterised COPY on
`${TARGET_ARCH}`, so a lane carries only its own flag file and an edit to one
arch's flags no longer re-keys `base` — and everything derived from it — on the
other two. Verified first that nothing ever reads a foreign arch's file:
`common.sh:65-66` tries only `arch-flags-${arch}.env` for the arch being built,
and media is built one `--platform` at a time.

The verifier's caveat was real and is handled: `ARG TARGET_ARCH` had **no**
default, so a hand-run build without `--build-arg` would have resolved the source
to `arch-flags-.env` and hard-failed where it used to work. It now defaults from
`TARGETARCH`, which BuildKit fills per platform — the ARG order had to be swapped
for that. Proven with a throwaway build rather than assumed: without `--build-arg`
it resolves to `amd64`, and with `--build-arg TARGET_ARCH=riscv64` to the riscv64
file. Linting a Dockerfile does not prove a COPY source expands.

**Still open, deliberately:** `Dockerfile.package:280` copies the whole
`03-media/core/` directory, so the runtime lane still takes all three files. That
is a directory COPY shared with several other consumers and wants its own change.

**What breaks.**
Backlog section G queues four riscv64-only skip-flag retirements
(MEDIA_SKIP_CSOUND, MEDIA_SKIP_GUDEV, MEDIA_SKIP_GLIB_STACK,
MEDIA_SKIP_CAIRO_PANGO_PIXBUF), each a one-line edit to
linux/scripts/03-media/core/arch-flags-riscv64.env, each to be 'proven by a
real riscv64 media stage'. That file is COPY'd unconditionally (line 174, the
last of the trio at 172-174) into the `base` stage that EVERY media stage
derives from, so the edit invalidates that layer and everything after it in
all three lanes. The amd64 and arm64 media builds then re-run from `base` —
onnxruntime cpu (1452.0s), app-wheelhouse (1523.5s), tvm (1377.1s), litert
(1353.6s), gstreamer (683.7s) and the rest — even though
`media_load_arch_flags` only ever sources the flag file for the arch being
built. Measured amd64 media stage = 134.3 min of RUN time, so one riscv64-only
flag flip costs ~4.5 h of amd64+arm64 recompile for zero behavioural change on
those arches.

**Evidence.**
linux/scripts/03-media/core/common.sh:64-71 — the candidate loop tries only
"/opt/scripts/03-media/core/arch-flags-${arch}.env" and the sibling-dir
fallback for the SAME ${arch}; nothing ever reads another arch's file (tree-
wide grep for 'arch-flags' returns only these three COPYs, common.sh:65-66,
and two comment references). `ARG TARGET_ARCH` is already declared at
Dockerfile.media:124, above the COPYs, so `COPY
linux/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env ...` would carry
exactly the one file the image reads. This is the identical shape F6 already
fixed for verify-media-artifacts.sh ('no longer sits in the shared base stage
(8 edits since 2026-08-01, each re-paying the whole media stage on every
arch)', archive-2026-09-02:309). git log since 2026-07-01: arch-flags-
riscv64.env 5 commits, arm64 3, amd64 2. Step timings from out/build-
logs/f2-media-validation.log (#34/#28/#30/#33/#69).

**Verifier's correction.**
The finding is real but should be restated on three points. SCOPE — it is the
trio (Dockerfile.media:172-174), not line 174 alone. An edit to arch-flags-
amd64.env (172) or arch-flags-arm64.env (173) has the same cross-arch blast
radius and is strictly worse, since it also invalidates the two COPYs below
it. The fix is ONE parameterized COPY replacing all three: `COPY --chmod=644
linux/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env
/opt/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env`. Caveat for whoever
does it: ARG TARGET_ARCH at :124 has NO default (the
`${TARGET_ARCH:-${TARGETARCH}}` fallback exists only in the ENV at :158, which
a COPY source cannot use), so a hand-run `nerdctl build -f
linux/Dockerfile.media` without --build-arg TARGET_ARCH would resolve to
`arch-flags-.env` and hard-fail where it works today. Give the ARG a default
(`ARG TARGET_ARCH=amd64`) or the narrowing trades a cache win for a new build
break. TIMING — the riscv64 proof build itself costs nothing on the other
lanes. build-cross-chain.sh:17-18 takes TARGET_ARCHES from
resolve_arch_list/CROSS_TARGETS, so `CROSS_TARGETS=riscv64` builds only that
lane. The wasted amd64/arm64 recompile is paid on the NEXT 3-arch chain, which
would otherwise have hit cache on those two media stages. "Re-runs the whole
amd64 and arm64 media stage" is right for a 3-arch build, not for the single-
arch proof the backlog prescribes. NUMBER — "~4.5 h" is derived, not measured.
134.3 min is the measured amd64 warm-ccache media stage (F6, out/build-
logs/f2-media-validation.log); the arm64 figure was never measured in that
log. Honest statement: ~2.2 h on amd64 plus an unmeasured arm64 stage of
similar or greater size. The ccache/sccache cache mounts survive the
invalidation, so this is already the warm number — it does not shrink further.
ALSO WORTH NAMING — the same edit re-keys the runtime lane too:
Dockerfile.package:278 COPYs the whole `linux/scripts/03-media/core/`
directory, so all three arches' runtime `package` stages rebuild as well. That
stage is cheap relative to media, but it means the blast radius is wider than
the media stage alone.

### WB. The whole linux/scripts/patches/ tree is bind-mounted into 8 media RUNs, each of which reads only its own subdirectory [high]

`linux/Dockerfile.media:648`

**FIXED 2026-09-03.** Each of the eight RUNs now mounts only the subdirectory it
reads, so deleting a GStreamer-only or libyuv-only patch no longer re-runs
app-wheelhouse, litert, genai, opencv, opencv-gst and libcamera.

Mapped rather than guessed: a tree-wide grep finds exactly six files naming
`/opt/scripts/patches/<sub>`, all literal paths, no variables. Mount by mount —
genai→`onnxruntime-genai`, litert→`litert`, opencv→`opencv`,
app-wheelhouse→`torchvision`, gstreamer build→`gstreamer`,
libcamera→`libcamera`+`libyuv`, opencv-gst→`opencv`.

**One mount was simply unused and is gone:** the gstreamer `install-deps.sh` RUN
mounted the whole tree and the script never mentions patches; it sources only
`common.sh` and `vulkan.sh`, neither of which is a consumer.

Two checks that mattered. Nothing enumerates the patches ROOT in the media lane —
the three `_patches_root=/opt/scripts/patches` hits are two android-lane files and
one comment — and `patch-gstreamer-sources.sh` guards on
`[ -d /opt/scripts/patches/gstreamer ]`, which the narrowed mount satisfies
exactly. Proven with a throwaway build: both subdirectories are present and the
un-mounted `opencv` is correctly absent, so the isolation is real and not just
lint-clean. `cerbero` and `onnxruntime` are android-lane patches and were never
part of these mounts.

**What breaks.**
Backlog items UA and UC delete patches/gstreamer/{003,004,005a,005b,006}; UD
deletes patches/libyuv/001. Any of those edits changes the content digest of
the whole-directory bind mount and therefore re-runs six RUNs that never read
the touched subdirectory: app-wheelhouse (line 648, 1523.5s), litert build
(line 472, 1353.6s), ORT genai (line 344, 371.8s), opencv build (line 606,
93.8s), opencv-gst (line 1016, 127.1s) and libcamera (line 963, 72.6s). That
is ~59 min per lane on a WARM amd64 ccache — roughly 3 h across the three
arches, more on the arm64/riscv64 cross lanes — bought by deleting a
GStreamer-only or libyuv-only patch file. The reverse also holds: the queued
GEN1 riscv64 genai patch work re-pays app-wheelhouse and litert on every arch.

**Evidence.**
Each consumer names exactly one (or, for libcamera, two) subdirectories:
build-litert.sh:533 -> /opt/scripts/patches/litert; build-
opencv.sh:242,259,263 -> /opt/scripts/patches/opencv; build-app-
wheelhouse.sh:646 -> /opt/scripts/patches/torchvision; 60-build-genai.sh:117
-> /opt/scripts/patches/onnxruntime-genai; build-libcamera.sh:32,45 ->
/opt/scripts/patches/libcamera + /opt/scripts/patches/libyuv; patch-gstreamer-
sources.sh:9-11 -> /opt/scripts/patches/gstreamer. The mount is identical
(`source=linux/scripts/patches`) at Dockerfile.media:344, 472, 606, 648, 870,
912, 963, 1016. Durations from out/build-logs/f2-media-validation.log steps
#28, #33, #39, #46, #74, #73. F6 (archive-2026-09-02:309) narrowed the ORT
`--step cpu` and tvm mounts by exactly this reasoning but left the patches
mount whole-tree everywhere; no backlog or archive entry mentions
scripts/patches as a cache-key surface.

**Verifier's correction.**
CONFIRMED with a corrected blast radius. `linux/scripts/patches` is bind-
mounted whole-tree into 8 RUNs in linux/Dockerfile.media (344, 472, 606, 648,
870, 912, 963, 1016) while every consumer reads exactly one file — apply-
patch.sh:18 and android-build-preamble.sh:107-123 both take a single patch
path and never glob. BuildKit puts the whole mounted subtree in each RUN's
cache key; the repo already proved this and gated it on the Windows lane
(docs/windows-build-invariants.md:670-684, "Every file under a directory mount
is part of that RUN's cache key" — it cost a full LLVM 23.1.0 recompile and is
now enforced by BuildKit.ModuleClosure.Tests.ps1). Linux has no such gate.
Three corrections to the claim: (1) OVERCOUNTED for the UA/UC trigger.
libcamera (963, 72.6s) and opencv-gst (1016, 127.1s) are NOT recoverable waste
when a gstreamer patch is deleted: 943:FROM gstreamer and 994:FROM gstreamer,
and RUN 912 (build-gstreamer-stage.sh -> patch-gstreamer-sources.sh:9-11)
genuinely reads patches/gstreamer, so the parent stage legitimately rebuilds
and both children follow regardless of their own mounts. Recoverable there is
genai 371.8s + litert 1353.6s + opencv 93.8s + app-wheelhouse 1523.5s =
3342.7s ~= 56 min per lane on warm amd64 ccache, plus the inert re-run of
gstreamer install-deps (870) and whatever RUNs follow each invalidated one
inside its stage. (2) UNDERCOUNTED for the opposite trigger, which is the
bigger one. The gstreamer stage carries the same whole-tree mount twice (870,
912), so editing patches/libyuv/001 (UD), patches/onnxruntime-genai/001 (the
queued GEN1 work) or patches/torchvision/001 re-pays the entire gstreamer
build — the dominant RUN in that half of the file — plus libcamera and opencv-
gst downstream, on every arch. (3) MISSED INSTANCE.
linux/scripts/patches/generate-patches.sh is host-only tooling that never
executes in any image (its only in-repo reference is the error message at
apply-patch.sh:63) yet sits inside the mounted tree, so editing it re-keys all
8 RUNs on all three arches for zero build effect — the exact shape F6 already
fixed for verify-media-artifacts.sh and linux/qnn-sdk/*.md. On prior art: no
backlog or archive entry mentions scripts/patches (grep is empty), and F6's
"Still open here" list names only the genai/wasm/js script mounts.
docs/gen1-riscv64-genai.md:165-172 does discuss the patches mount as a cache-
key surface, but only for the genai RUN and only to argue it is redundant with
the already-broad 03-media/build/onnxruntime tree mount; it never considers a
patch edit in one component re-paying another component's stage, which is the
finding. Fix note: narrow each mount to the per-component SUBDIRECTORY, not to
the individual .patch file — a file-level mount source that later gets deleted
makes BuildKit fail at cache-key time ("not found"), turning every future
patch removal into a Dockerfile edit as well.

### WC. SHIPPED-TRUTH A is inert for 10 of its 16 keys: the in-image probe emits no ADV line for them, so every one is a permanent SKIP [high]

`linux/scripts/06-packaging/smoke-runtime-image.sh:665`

**FIXED 2026-09-03.** All ten rows have an `ADV` probe now, and
`FROZEN_UNPROBED` is **empty** — the gate refuses any new row without one, with
no baseline left to hide behind.

It turned out to be the cheap half of the work: every one of the ten already had
a `HAVE` probe and an `ENV` in `Dockerfile.package`; only the `ADV` line was
missing, so the row could never do more than SKIP. **And the shipped image is
clean** — running the real comparison against `latest-cross-amd64` gives OK on
all nine checkable keys (genai has its own dedicated gate). The existing
normalisation already handles the format gap: ADV `v1.29.0` against HAVE
`1.29.0`, and IREE's `3.11.0.dev0+e4a3b04…` reduces to `3.11.0`. So nothing was
hiding behind the inert rows — but from now on nothing can.

Two things this shook out. The `code-size` gate added an hour earlier caught the
ten new lines growing both the file and `_shipped_truth_probe` past their frozen
numbers, which exposed a design error in its own contract: "frozen numbers may
only go DOWN" would have forbidden a legitimate addition to an already-oversized
file, and a gate that blocks correct work gets routed around. It now requires the
number to MATCH in both directions, so growth is allowed but lands in the diff
next to a reason. And `test-advertised-keys.sh`'s anti-rot case had been reading
the live baseline; with that empty it silently stopped testing anything, so the
fixture seeds its own entry.

**What breaks.**
Bump `ARG ONNXRUNTIME_VERSION=v1.29.0` to `v1.30.0` in
linux/Dockerfile.package:175 (or let
IREE/OPENCV/LITERT/PYAV/CMAKE/NODE/UV/UBUNTU drift from what is actually
built). Dockerfile.package:180-189 turns all ten of those ARGs into ENV, so
the shipped wrapper advertises `ONNXRUNTIME_VERSION=v1.30.0` while carrying
1.29.0. `_shipped_truth_probe` has no `printf 'ADV ONNXRUNTIME_VERSION'` line,
so `adv` is empty in `_advert_verdicts` (line 817) and the gate emits `SKIP
ONNXRUNTIME_VERSION image sets no ONNXRUNTIME_VERSION -- nothing advertised to
check`. `check_advertised_versions` (line 991) only fails when ok+bad == 0,
and the six ADV-backed keys keep that count non-zero, so the gate prints `pass
"all 6 advertised version(s) match the shipped image"` and the manifest ships.
Downstream consumers read the env label; the SKIP message is itself false (the
image does set the key).

**Evidence.**
ADV printfs exist only at lines 665-671 (PYTHON_VERSION, PYTHON_MAJOR_MINOR,
GCC_VERSION, LLVM_RELEASE, GSTREAMER_VERSION, VULKAN_VERSION, PYTORCH_EXTRA).
HAVE printfs exist for 16 keys (672-704). `_ADVERTISED_VERSION_KEYS` (line
784) lists 16. I ran `_advert_verdicts` verbatim (extracted with sed, no repo
mutation) against a probe carrying deliberately wrong HAVE values -- OPENCV
4.9.0, ONNXRUNTIME 1.27.0, IREE 3.10.0, LITERT 1.0.0 -- and got: `SKIP
UBUNTU_VERSION`, `SKIP CMAKE_VERSION`, `SKIP NODE_VERSION`, `SKIP UV_VERSION`,
`SKIP OPENCV_VERSION`, `SKIP ONNXRUNTIME_VERSION`, `SKIP
ONNXRUNTIME_GENAI_VERSION`, `SKIP PYAV_VERSION`, `SKIP IREE_VERSION`, `SKIP
LITERT_VERSION` -- zero BAD rows. Only
PYTHON_MAJOR_MINOR/GCC_VERSION/LLVM_RELEASE/GSTREAMER_VERSION/VULKAN_VERSION
produced verdicts. Corroborating: docs/cross-build-verification.md:398 and
:448 still describe the gate as covering exactly the six ADV-backed keys ('the
advertised-version table only covers the six keys listed above'), and its
mutation record says 'A fails the vacuous-pass guard after six loud SKIPs' --
the table was widened to 16 without widening the probe. docs/refactoring-
backlog.md:619 records the opposite belief ('The advert-keys gate compares the
RUNTIME's numeric prefix, so this skew is currently green'), so the IREE
compiler/runtime skew entry is filed under a mechanism that never runs.

**Verifier's correction.**
The claim is real but overstated in three places and understated in one.
CORRECT AS CLAIMED: `_shipped_truth_probe` (smoke-runtime-image.sh:661-708)
emits `ADV` for only 7 names while `_ADVERTISED_VERSION_KEYS` (784) lists 16,
so ten keys can never reach the comparator's OK/BAD arms. Running the real
`_advert_verdicts` against a probe with deliberately wrong HAVE values yields
5 OK / 11 SKIP / 0 BAD. The SKIP text is factually false:
Dockerfile.package:180-189 does ENV those keys. CORRECTION 1 — it is 11 of 16,
not 10. PYTHON_VERSION also SKIPs, because Dockerfile.package:199 deliberately
does not ENV it ("nothing stages /opt/python-cross into this image"). So the
gate's success line reads `all 5 advertised version(s) match the shipped
image`, not 6. CORRECTION 2 — the proposed trigger cannot happen. Hand-bumping
`ARG ONNXRUNTIME_VERSION=v1.30.0` in Dockerfile.package is caught at preflight
by linux/scripts/01-core/verify-arg-consistency.sh:64-92 (slug `arg-
consistency`), which fails when any Dockerfile ARG literal default differs
from versions.env. The real trigger is the opposite direction: the label
agrees with versions.env while the SHIPPED ARTIFACT does not — a PyPI wheel
shadowing the source build, a `--no-deps` install, a distro binary winning
PATH, or a dev-tagged build. That is precisely the skew gate A was written
for. CORRECTION 3 — four of the ten keep a second net. `check_ml_version_pins`
(smoke-runtime-image.sh:355) delegates to smoke-torch-venv.sh
`assert_pinned_versions` (line 75), which compares ONNXRUNTIME_VERSION,
ONNXRUNTIME_GENAI_VERSION, LITERT_VERSION and OPENCV's MAJOR against the in-
image versions.env (lines 94-98). Those four would still red on a gross
mismatch. CORRECTION 4 (understated) — the genuinely unguarded set is
IREE_VERSION, PYAV_VERSION, OPENCV minor/patch, UBUNTU_VERSION, CMAKE_VERSION,
NODE_VERSION and UV_VERSION: no other gate in linux/scripts compares any of
them to anything. IREE is the live instance — docs/refactoring-backlog.md:619
records the CONFIRMED `iree-base-compiler 3.11.0` vs `iree-base-runtime
3.11.0.dev0+e4a3b04` skew as "currently green" because "the advert-keys gate
compares the RUNTIME's numeric prefix", and that comparison never executes.
Were the runtime to drift to 3.10.0, the image would ship advertising
IREE_VERSION=v3.11.0 and the smoke would print `SKIP IREE_VERSION image sets
no IREE_VERSION` then `pass all 5 advertised version(s) match`. ROOT CAUSE
(not in the claim): commit d27cdee1 fixed only the Dockerfile half; `git show
d27cdee1 -- linux/scripts/06-packaging/smoke-runtime-image.sh` is an empty
diff. The missing enforcement is in verify-advertised-keys.py:63, which
computes `checked` from the `_ADVERTISED_VERSION_KEYS` string alone and never
requires a matching `ADV <key>` printf in the probe — its own FAIL message
asks for "a HAVE probe + a row in _ADVERTISED_VERSION_KEYS" and forgets the
ADV line it depends on. tests/test-advertised-keys.sh:54 synthesizes the ADV
line, so the suite cannot see the gap either. The one-line fix is ten more
`printf 'ADV <KEY> %s\n' "${<KEY>:-}"` lines in the heredoc; the durable fix
is to make verify-advertised-keys.py grep the probe for `ADV <key>` as well as
the table.

### WD. The two guards built to prevent an unchecked version key cannot detect a missing ADV probe: one checks list membership only, the other fabricates the ADV line [medium]

`linux/scripts/verify-advertised-keys.py:64`

**What breaks.**
Delete the line `printf 'ADV GSTREAMER_VERSION %s\n' "${GSTREAMER_VERSION:-}"`
from `_shipped_truth_probe` (smoke-runtime-image.sh:669) -- a plausible edit
while reworking the probe. `verify-advertised-keys.py` builds `checked` purely
from the `_ADVERTISED_VERSION_KEYS` string (line 62-64), so preflight slug
`advert-keys` still reports 'OK: every advertised version key is checked or
excused'. `linux/scripts/tests/run-tests.sh` still passes, because test-
advertised-keys.sh:54 constructs `"ADV $1 $2\nHAVE $1 $3"` itself instead of
driving the real probe. The runtime smoke silently demotes GSTREAMER_VERSION
to a SKIP row and a wrong GStreamer label ships green. This is the mechanism
that let finding #1 happen and will let it recur after any point fix.

**Evidence.**
`verify-advertised-keys.py:62-64` builds its `checked` set by regexing
`_ADVERTISED_VERSION_KEYS="…"` out of the smoke -- nothing ever greps for the
probe line that would supply the value. Its own failure text (76-79) tells you to
add both a probe and a table row, but only the row is verified. The unit test
cannot catch it either: `tests/test-advertised-keys.sh:54` builds the probe output
by hand instead of driving the real probe. The probe's own contract is documented
in docs/cross-build-verification.md -- that page owns it; this entry only records
that nothing checks the two halves against each other.

**Verifier's correction.**
Accurate statement: neither guard verifies that the in-image probe actually
emits an `ADV <key>` line, so a key can sit in `_ADVERTISED_VERSION_KEYS` and
be reported fully covered while never being compared. This is not a latent
risk — it is the current state for 10 of the 16 keys. `_shipped_truth_probe`
(linux/scripts/06-packaging/smoke-runtime-image.sh:665-671) emits ADV for only
PYTHON_VERSION, PYTHON_MAJOR_MINOR, GCC_VERSION, LLVM_RELEASE,
GSTREAMER_VERSION and VULKAN_VERSION (plus PYTORCH_EXTRA). UBUNTU_VERSION,
CMAKE_VERSION, NODE_VERSION, UV_VERSION, OPENCV_VERSION, ONNXRUNTIME_VERSION,
ONNXRUNTIME_GENAI_VERSION, PYAV_VERSION, IREE_VERSION and LITERT_VERSION are
in the 16-key table (smoke:784-787), have working HAVE probes (smoke:692-701)
and are ENV-set in the shipped image (linux/Dockerfile.package:180-189), yet
`_advert_verdicts` (smoke:820, 825-826) sees an empty `adv` and emits `SKIP
<key> image sets no <key> -- nothing advertised to check` — a reason that
stopped being true when commit d27cdee1 added those ENVs. Gate A therefore
still asserts 5 rows, not 16. The three guards that should catch this cannot:
verify-advertised-keys.py:58-64 derives `checked` from the table string alone;
the vacuous-pass guard (smoke:1009-1010) only fires when *every* key skips;
and test-advertised-keys.sh:54 hand-writes the ADV line it tests against. The
consequence is a documentation/artefact divergence the repo already published:
docs/refactoring-backlog-archive-2026-09-02.md:432-437 says "16 keys are
checked", Dockerfile.package:169 says the SKIPs were fixed, and docs/cross-
build-verification.md:398-400 and 448-450 still describe six keys — while the
shipped gate compares five. The correct guard is to have verify-advertised-
keys.py require, for each key in `_ADVERTISED_VERSION_KEYS`, both an `ADV
<key>` and a `HAVE <key>` emitter in the probe, and/or to have the smoke fail
(not SKIP) when a key the image genuinely ENV-sets produced no ADV row. The
claim's specific illustration is the one inaccurate part: the `ADV
GSTREAMER_VERSION` line at smoke:669 still exists and is one of the rows that
does assert, so that deletion is hypothetical; the ten ENV-only keys are the
live instance.

**PARTLY CLOSED 2026-09-03.** The blind spot is gone for anything NEW:
`verify-advertised-keys.py` now extracts the `ADV <KEY>` printfs from the smoke
and fails a table row that has none, and it fails just as hard when a frozen row
gains a probe without leaving the baseline — so the freeze cannot rot into
cover for the next one. The 10 already-inert rows are frozen in
`FROZEN_UNPROBED` and reported on every run; retiring them is WC, and each
retirement must delete its baseline entry or the gate says so. Both mutations
were proven to go red (4 of 17 assertions in `test-advertised-keys.sh`), and the
fixture copies the smoke rather than touching it — that file is inside the
closure the chain was re-reading at the time.

### WE. check_healthcheck_exec runs a hardcoded copy of the HEALTHCHECK, not the image's own; check_healthcheck_config only asserts the constant Test[0] [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:1206`

**FIXED 2026-09-03.** Both halves. A new `_rt_healthcheck_cmd` reads the image's
OWN probe — `Test[0]` is the OCI verb, the command is what follows — and the exec
gate now runs THAT instead of a hardcoded copy, naming it in both verdicts. The
config gate reports the command rather than the constant verb.

Demonstrated against the published image: the helper reads
`/opt/venv/bin/python3 -c "import onnxruntime" || exit 1` and it runs clean,
while the old gate read `CMD-SHELL`. Reverting the extraction makes the exec gate
try to run the verb — the failure message says `unhealthy: CMD-SHELL`, which is
the bug stated in one line.

**What breaks.**
Edit linux/Dockerfile.torch:149 to `CMD /opt/venv/bin/python -c "import
orchestr_ant_ion.server" || exit 1` (a rename, a venv interpreter path change,
or a probe swap). Every shipped container then flaps `unhealthy` and
orchestrators refuse to route to it. Both healthcheck gates stay green:
`check_healthcheck_exec` executes its own hardcoded `/opt/venv/bin/python3 -c
'import onnxruntime'`, which still works, and `check_healthcheck_config` (line
141) reads `hc.get('Test',[''])[0]`, which is the OCI verb `CMD-SHELL`/`CMD`,
never the command -- so it can only distinguish 'a HEALTHCHECK exists' from
'none', not right from wrong. The runtime smoke exits 0 and build-runtime-
manifest.sh:309 publishes the index.

**Evidence.**
smoke-runtime-image.sh:1206 hardcodes `/opt/venv/bin/python3 -c 'import
onnxruntime'` under a comment claiming 'Run the ACTUAL HEALTHCHECK command,
not just parse its Test string'. linux/Dockerfile.torch:148-149 is the real
definition. check_healthcheck_config:146 prints `pass "HEALTHCHECK configured:
${healthcheck}"` where `${healthcheck}` is Test[0] -- a constant verb, so the
pass message also misreports what was checked. `inspect_image_config` is
already used elsewhere in the file (lines 22-24, 100), so reading the real
Test[1] and running it needs no new machinery. docs/refactoring-backlog-
archive-2026-08-10.md:478 records this as closed ('HEALTHCHECK now EXECUTED
not just [parsed]'), i.e. the repo believes the command is read from the
image.

**Verifier's correction.**
Accurate as stated, with two line-number/scope refinements. The hardcoded
probe is at smoke-runtime-image.sh:1207 (function opens :1202, comment :1199).
And check_healthcheck_exec is not a gate that can never fail: it does catch a
broken venv interpreter or an unimportable onnxruntime — the cases its comment
names. What it cannot catch is the change class it was added to guard against:
any edit to Dockerfile.torch:149 itself. Because the command is a hand-
maintained duplicate rather than Config.Healthcheck.Test[1] read from the
image, the smoke keeps executing the OLD command after the HEALTHCHECK
changes, so both healthcheck gates stay green while every shipped container
reports unhealthy. check_healthcheck_config's Test[0] is confirmed constant in
production logs (`PASS HEALTHCHECK configured: CMD-SHELL`, out/build-
logs/runtime-retry2.log, all three arches), so it is present-vs-absent only
and its pass message misstates what was checked. Fix is one line each: read
Test[1] via the existing inspect_image_config helper, assert it non-empty, and
run that string instead of the literal.

### WF. The app-wheel ratchet silently disarms when the ok-count cannot be parsed, falling back to the exit status the ratchet exists to distrust [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:254`

**FIXED 2026-09-03.** An ok-count that does not parse now FAILS. It used to
short-circuit into the pass branch and print `? ok >= 15`, leaving only the exit
status — which the comment three lines above already documents as insufficient,
since the app exits 0 whenever failures==0 and reports a vanished component as a
WARNING.

**What breaks.**
The sibling app repo changes its summary wording (e.g. `=== 15/15 ok,` -> `===
15/15 passed,`) or the invocation gains `--json`. `sed -n 's/.*===
\([0-9]\{1,\}\)\/[0-9]\{1,\} ok.*/\1/p'` then matches nothing, `_wheel_ok` is
empty, `[ -n "${_wheel_ok}" ] && [ "${_wheel_ok}" -lt "${_wheel_floor}" ]`
short-circuits false, and control falls to the else branch which prints `pass
"app wheel smoke passed on-target (amd64, ? ok >= 15)"`. The gate is then back
to exit-status-only, which the comment at line 239-243 documents as
insufficient: the app exits 0 whenever `failures == 0` and reports a vanished
component as a WARNING. An amd64 wrapper that lost torchvision, tvm and pyav
(optional/warning results) ships as `latest-cross` with a green ratchet line
naming the floor it never enforced.

**Evidence.**
The count is produced by exactly one line in a DIFFERENT repo:
/home/bigjuicyjones/GitHub/Kataglyphis-Orchestr-ANT-
ion/orchestr_ant_ion/smoke/__main__.py:73 `f"=== {passed}/{len(results)} ok,
"`, reached only on the non---json path (line 68-74); `main` returns 0
whenever `failures` is empty (line 76), and `warnings` (optional checks) are
excluded from `failures` (line 58). ContainerHub pins that repo only by
APP_REF (linux/Dockerfile.torch:37, v0.0.27) -- nothing in ContainerHub gates
the output format, so this is an unguarded cross-repo string contract. The `?`
placeholder at smoke-runtime-image.sh:258 (`${_wheel_ok:-?}`) shows the empty
case was anticipated for the message but not for the verdict. Backlog line 84
tracks raising the riscv64 floor 12 -> 13 but not this parse hole.

**Verifier's correction.**
The mechanism is exactly as claimed, but three parts of the offered scenario
are overstated and should be restated: 1. THE HEADLINE EXAMPLE IS PARTLY
WRONG. `check_arch_parity` (smoke-runtime-image.sh:584-618) independently
asserts dist-info presence for `_PARITY_WHEELS = "torch torchvision
ai_edge_litert iree_base_compiler iree_base_runtime onnxruntime_genai"` (line
534) against a per-arch exemption list (`_parity_exempt`, line 540-553) that
grants amd64 nothing. An amd64 wrapper that LOST torchvision would therefore
fail ARCH-PARITY regardless of the ratchet. The correct blast radius is
narrower and split in two: - components absent from `_PARITY_WHEELS` — tvm,
pyav/av, pillow, opencv-python — where a vanished wheel is caught by nothing
but the ok-count; and - PRESENT-BUT-BROKEN wheels on any arch, including
torchvision, since check_arch_parity reads dist-info directories only and
never executes the wheel. That second case is precisely the failure the
ratchet was built for (archive-2026-08-10.md:425 records the app-wheel smoke
catching a broken LiteRT that imported fine). 2. "SILENTLY" NEEDS
QUALIFICATION. The app is pinned by tag (`APP_REF=v0.0.27`,
linux/scripts/01-core/versions.env:329, mirrored at
linux/Dockerfile.torch:37/102), so an upstream push cannot drift the format
into a running build. The trigger is a deliberate ContainerHub commit bumping
APP_REF to an app version whose summary wording changed. The `--json` half of
the scenario is not reachable at all: line 252 invokes `python -m
orchestr_ant_ion.smoke` as a fixed literal with no flag forwarding, so
`--json` requires editing ContainerHub. The defect is that such a bump disarms
the ratchet with nothing going red — not that the format can drift on its own.
3. IT IS INVISIBLE TO THE GATE, NOT TO A READER. Line 258 prints `? ok >= 15`
via `${_wheel_ok:-?}`, and line 253 dumps the full smoke output, so a human
reading the chain log can see the parse failed. The defect is that the verdict
is green and FAILURES is not incremented. Accurate statement: the app-wheel
ratchet's floor comparison is guarded by `[ -n "${_wheel_ok}" ]`, so an
unparseable ok-count routes to `pass` instead of `fail`. The floor is then
unenforced and the verdict reverts to the app's exit status, which is 0
whenever `failures` is empty and treats every optional check (tvm, pyav,
cv2-dnn, cv2-freetype, litert, iree) as a warning. This is reachable via an
APP_REF bump to an app whose summary wording changed, and it leaves present-
but-broken wheels and the untracked components (tvm, pyav, pillow, opencv-
python) with no gate at all. The fix matches the pattern already used 20 lines
below for the ONNX-EP sentinel: `fail` when the count cannot be parsed rather
than falling through to `pass`.

### WG. `if ! build_canadian_native_gcc_for …` disables errexit for the whole multi-hour builder run, so build-gcc.sh's exit code is discarded [high]

`linux/scripts/02-toolchain/gcc.sh:383`

**FIXED 2026-09-03.** The builder invocation now ends in an explicit
`|| die`, so its exit code is raised instead of discarded. That is the whole
fix: `die` resolves to `err`, which does `exit 1`, and an `exit` is not
suppressed by the `if !` context — while `errexit` is. With the builder raising,
the documented `GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE` skip becomes the only
remaining non-zero return, which is exactly what the `if !` was written for, so
the call site itself needs no change.

New suite `test-gcc-errexit-contract.sh`. The function needs a cross toolchain
and a sysroot, so it cannot be unit-tested; what is tested is the contract, plus
one characterisation test recording that `if ! f` really does suppress errexit
inside `f` — the behaviour is easy to misremember and the cost of forgetting it
is a silent multi-hour build. **My first version of the guard test was vacuous:**
it grepped a 24-line window after the invocation, which also caught the `|| die`
on the two `-x` checks below, so it passed with the guard removed. It now walks
the invocation's own continuation lines. Mutating the guard away fails it.

**What breaks.**
During the Canadian native GCC build for arm64/riscv64, `bash
"${GCC_CROSS_BUILDER}" …` (gcc.sh:315) runs `make install-gcc install-target-
libgcc install-target-libstdc++-v3 install-target-libatomic` (build-
gcc.sh:865). `install-gcc` runs first and installs ${native_prefix}/bin/gcc
and bin/g++; if a later target then fails — ENOSPC mid-install (this repo's
recurring disk emergency), or the libstdc++ std-module breakage the tree
already has a patch for — make stops and build-gcc.sh (set -Eeuo pipefail)
exits 1. Because build_canadian_native_gcc_for is invoked as the condition of
`if !`, bash suppresses errexit for its entire dynamic extent, so that non-
zero exit does NOT abort: execution falls through to gcc.sh:326-327 `[ -x
"${native_prefix}/bin/gcc" ] || die` and `[ -x …/g++ ] || die`, which both
PASS (install-gcc already put them there), then to assert_gcc_elf_arch
(gcc.sh:332-333), which only reads the ELF header (gcc.sh:105-130 — readelf +
a Machine: string compare, it never compiles or links anything). The
function's last statement is `log "Installed native GCC …"`, so it returns 0,
the `if !` sees success and prints no warning, and the toolchain stage reports
green while shipping a target-native GCC with no target libstdc++/libatomic.
The failure resurfaces hours later in Dockerfile.android's GCC swap or in the
first C++ compile that uses it.

**Evidence.**
gcc.sh:383 `if ! build_canadian_native_gcc_for "${full_version}" "${prefix}"
"${triplet}" "${normalized_target}"; then`. The comment directly above it
(gcc.sh:380-382) states the intent: "build_canadian_native_gcc_for returns 1
(instead of dying) when the opt-in skip knob is set; keep that skip from
aborting the remaining targets even with errexit live" — i.e. the `if !` is
meant to tolerate exactly one `return 1` (gcc.sh:288,
GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE), but it also swallows every other
non-zero status inside the function, including the builder's. Note the
contrast: every OTHER failure in that function is raised with `die`
(gcc.sh:265, 266, 290, 326, 327), which calls `err` → `exit 1` (logging.sh:79)
and therefore survives the suppression; only the builder invocation at
gcc.sh:315 relies on errexit and is the one that is lost. Suppression
confirmed empirically on this host's bash 5.3.9: `set -euo pipefail; f() {
bash -c "exit 3"; echo REACHED; return 0; }; if ! f; then echo saw; fi` prints
REACHED and exits 0. Related, same file: the parallel driver's per-target
subshell (gcc.sh:475 `( JOBS=… _gcc_build_cross_target "${t}" ) > log 2>&1 &`)
routes through the same `if !`, so a parallel target build hits it too. Not
present in docs/refactoring-backlog.md or any refactoring-backlog-archive-*.md
(greps for 'canadian', 'errexit', 'GCC_CANADIAN' return only unrelated
entries).

**Verifier's correction.**
The core is real: at linux/scripts/02-toolchain/gcc.sh:383 the `if !` wrapper
— added to tolerate the single `return 1` at gcc.sh:290
(GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE) — also disables errexit for the
multi-hour `bash "${GCC_CROSS_BUILDER}"` invocation at gcc.sh:315, whose exit
code is then discarded, and the only checks that follow (gcc.sh:326-327 `[ -x
] || die`, gcc.sh:332-333 readelf-only assert_gcc_elf_arch defined at
gcc.sh:105-131) cannot detect a partially-installed toolchain. Scope nit:
errexit is suppressed for the function's dynamic extent, not "the whole
builder run" — but that extent contains the entire builder call, so the
practical effect is as claimed. Two specifics need fixing. (1) Both named
triggers are wrong. The libstdc++ std-module/fenv failure is recorded in-tree
at gcc.sh:300 as `make[3]: [Makefile:868: stamp-modules-bits] Error 1
(ignored)` — make ignores it, so build-gcc.sh never exits non-zero for it. And
any failure during the compile phase (build-gcc.sh:737 `make -j"${JOBS}" all-
gcc all-target-libgcc all-target-libstdc++-v3 all-target-libatomic`) occurs
BEFORE any install, leaving ${native_prefix}/bin/gcc absent, so gcc.sh:326 `||
die` does hard-fail. The genuine silent window is narrow: only a non-zero exit
AFTER `make install-gcc` has already placed bin/gcc, i.e. a failure in the
later targets of the single install command at build-gcc.sh:762 (`make
install-gcc install-target-libgcc install-target-libstdc++-v3 install-target-
libatomic`) — ENOSPC being the realistic case given this repo's recurring disk
pressure — or in the final unguarded `rm -rf "${BUILD_DIR}"` at build-
gcc.sh:856 (every other post-install command is `|| true`-guarded). (2) It
does not ship a broken artifact. linux/scripts/06-packaging/smoke-runtime-
image.sh:1265 check_native_compiler_battery (invoked at :1419)
compiles+links+RUNS C `-latomic` and C++ hello/exceptions+STL/std::thread/LTO
under binfmt/qemu and hard-`fail`s, and validate-compilers.sh's C link smoke
hard-fails in Dockerfile.package on a missing libgcc. So the accurate impact
is: the toolchain stage's Canadian-cross gate cannot fail for a builder
failure that happens after install-gcc, it prints "Installed native GCC …" and
goes green, and the defect only surfaces at the end-of-chain runtime smoke
hours later — note swap-native-gcc.sh:143 `_smoke_native_gcc` is warning-only,
so the android stage does not catch it either. Minimal fix: capture the status
instead of suppressing it, e.g. `local _rc=0; build_canadian_native_gcc_for …
|| _rc=$?` and treat `_rc=1` (the documented skip) as tolerable while dying on
anything else, or have the skip path set a sentinel variable rather than
returning 1.

### WH. RUST_VERSION never reaches the package stage: both rustc-pin gates are structurally inert, and the shipped image resolves rustc/cargo to Ubuntu 1.93.1 against a 1.98.0 pin [high]

`linux/scripts/06-packaging/setup-package-image.sh:463`

**FIXED 2026-09-03 — and the finding was HALF STALE.** Checked against the run
that had just published rather than the log the audit cited (`runtime-retry2.log`,
an older run), then against the shipped image itself:

```
rustc 1.98.0   cargo 1.98.0   default: 1.98.0-x86_64-unknown-linux-gnu
```

So **the version skew does not exist.** "The shipped image resolves rustc/cargo
to Ubuntu 1.93.1" was the 2026-08-07 state, fixed by the two COPYs now at
`Dockerfile.package:110-111`, and the `(no --version)` in the build log is a probe
artefact from before the toolchain env is wired, not a broken image.

What WAS real, and confirmed on the published run (6 NOTEs, two per arch): the
gate is **inert**, because `RUST_VERSION` never reaches the package stage. A gate
written after an incident, that cannot fire, would not have caught the next one.

Fixed at both levels. `Dockerfile.package` now declares `ARG RUST_VERSION` and
puts it in the ENV block that runs before `setup-package-image.sh`, so
`report_rust_provenance` actually compares. And `RUST_VERSION` moved out of
`verify-advertised-keys.py`'s EXCUSED list — its excuse read "rustc is not shipped
in the runtime image", which the container above disproves — into the checked
table with both an `ADV` and a `HAVE` probe. The HAVE probe was verified against
the real image: it extracts `1.98.0`, matching the pin.

Note the interlock: adding a table row without a probe would have failed the
FROZEN_UNPROBED check added for WD this morning, which is why both probes exist.

**What breaks.**
`report_rust_provenance()` is the HARD GATE added after the 2026-08-07
incident (its own comment at lines 456-462: "if the shipped rustc does not
match RUST_VERSION, the image is wrong and this build stops... Never again
silently"). It opens with `local want="${RUST_VERSION:-}"` and returns 0 with
a NOTE when that is empty. RUST_VERSION is empty on every single build of the
package stage: `linux/Dockerfile.package` declares no `ARG RUST_VERSION` and
no `ENV RUST_VERSION` anywhere (the only Dockerfile ARG in the Linux tree is
`Dockerfile.toolchain:229`, a different image), `linux/Dockerfile.base` never
exports it either, and `setup-package-image.sh` sources only `platform.sh` +
`package-lists.sh`, never `versions.env` (the file's own comment at line ~353
states this: "this script sources platform.sh/package-lists.sh only, not
common.sh, so nothing loads the baked versions.env into its env"). The twin
guard in `wire_cargo_symlinks()` at line 317 (`if [ -n "${RUST_VERSION:-}" ]
&& [ -x "${CARGO_HOME}/bin/rustc" ]`) is gated on the same empty variable and
is skipped as well. Net effect measured live on all three arches in the
2026-09-02 runtime build: the package image resolves `cargo` and `rustc` to
Ubuntu's debs (`/bin/rustc -> /usr/lib/rust-1.93/bin/rustc`, rustc 1.93.1)
while `linux/scripts/01-core/versions.env:113` pins `RUST_VERSION=1.98.0` —
i.e. the exact regression these gates exist for is live again and both gates
printed the skip line instead of failing. Nothing downstream catches it:
`verify-advertised-keys.py:23` EXCUSES `RUST_VERSION` with the reason "a
build-stage toolchain; rustc is not shipped in the runtime image", which is
false — `linux/Dockerfile.package:110-111` COPYs `/usr/local/rustup` and
`/usr/local/cargo` into the runtime image precisely so it is shipped — so the
smoke's advertised-vs-actual gate skips it too, and `grep -n 'rust\|cargo'
linux/scripts/06-packaging/smoke-runtime-image.sh` returns zero hits. A
consumer (the comment names Kataglyphis-RustProjectTemplate) hits an MSRV
error that blames its own dependency.

**Evidence.**
Code: setup-package-image.sh:463-466 `local want="${RUST_VERSION:-}" got` /
`if [ -z "${want}" ]; then echo " NOTE: RUST_VERSION unset; cannot verify the
toolchain matches its pin." >&2; return 0`. Same file:317 `if [ -n
"${RUST_VERSION:-}" ] && [ -x "${CARGO_HOME}/bin/rustc" ]; then`. Live proof,
/home/bigjuicyjones/GitHub/Kataglyphis-ContainerHub/out/build-logs/runtime-
retry2.log, three occurrences (lines 402047-402052 amd64, 1358864-1358869
arm64, 2046845-2046850 riscv64): `#49 60.38 cargo /bin/cargo ->
/usr/lib/rust-1.93/bin/cargo (cargo 1.93.1 ...)` `#49 60.41 rustc /bin/rustc
-> /usr/lib/rust-1.93/bin/rustc (rustc 1.93.1 ...)` `#49 60.50 NOTE:
RUST_VERSION unset; cannot verify the toolchain matches its pin.` On
arm64/riscv64 the same block also shows `rustup /usr/local/cargo/bin/rustup ->
... (no --version)` — the copied rustup is an x86_64 binary there. Secondary
observation on the mechanism: `_link_unless_rustup_provides()` at setup-
package-image.sh:298 accepts a DANGLING symlink as "rustup provides it" (`[ -e
"${link_path}" ] || [ -L "${link_path}" ]`), so its documented apt fallback
does not fire for a broken link — the log shows all six "Keeping existing
/usr/local/cargo/bin/<tool>" lines immediately before `command -v` still lands
on /bin. Backlog checked: `grep -n 'RUST_VERSION|rustc' docs/refactoring-
backlog.md docs/refactoring-backlog-archive-*.md` returns only the unrelated
meson `rustc.cmd_array()` item (UA) and a Windows-lane note; `grep -i 'rust
provenance|RUST_VERSION unset|1.93.1'` across backlog + CHANGELOG + changelog
archives returns nothing.

**Verifier's correction.**
The claim is accurate as written; two refinements. (a) Date of the live
evidence: the proof is in out/build-logs/runtime-retry2.log with mtime
2026-08-27 14:06, not the "2026-09-02 runtime build" the claim names. The line
numbers and content it cites are correct. (b) Missing mechanism detail that
sharpens the fix: the orchestrator is NOT failing to forward the value.
linux/scripts/01-core/version-forwarding.sh:26-40 forwards every versions.env
key not preceded by a `# noforward` comment, and versions.env:113
RUST_VERSION=1.98.0 carries no such marker — so `--build-arg
RUST_VERSION=1.98.0` IS passed to the package build and BuildKit discards it
because Dockerfile.package declares no matching ARG. version-forwarding.sh's
own header comment names this failure class exactly: "a build arg no
Dockerfile declares is ignored by BuildKit; forgetting to forward a consumed
variable is not". The fix is therefore a one-line `ARG RUST_VERSION` (plus an
ENV, if it should also be advertised in the image config) in
Dockerfile.package's `package` stage — not a change to the forwarding.
Additional supporting evidence for the "no gate covers this" leg: verify-arg-
consistency.sh:34-55 checks only the Dockerfile-ARG -> versions.env direction
(is every version-named ARG forwarded, and does its default match). It has no
check in the reverse direction — that a script running inside a stage which
reads ${VAR} has a corresponding ARG declared in that stage's Dockerfile — so
this whole class of "silently empty in the RUN" bug is invisible to the
preflight suite, not just this instance.

### WI. cross_stage_is_per_arch leaks its `for s` loop variable and silently corrupts the disk-guard's protected-slug list (base + compiler cache exports are never protected) [high]

`linux/scripts/01-core/stage-defs.sh:135`

**FIXED 2026-09-03** in the closure window that opened when the RVA23 chain
finished. `cross_stage_is_per_arch` now declares `local stage="$1" s`.
Demonstrated before and after: with the leak, a caller iterating
`base compiler runtime` reads back `android` for both non-per-arch stages —
exactly the arch-less `cross-android-` slug the live log printed. Regression
test in `test-stage-defs.sh`; removing `local s` fails it.

**What breaks.**
`cross_stage_is_per_arch()` declares `local stage="$1"` but NOT `local s`, and
iterates `for s in "${CROSS_PER_ARCH_STAGES[@]}"`. Its only caller that
iterates its own `s` is `_disk_guard_protected_slugs`
(linux/scripts/01-core/disk-guard.sh:68 `for s in "${CROSS_STAGE_ORDER[@]}"`,
:74 `if cross_stage_is_per_arch "${s}"`). On the return-1 path (a NON-per-arch
stage: base, compiler, runtime) the callee runs its loop to completion and
leaves the caller's `s` set to `android`, so line 81 evaluates
`cross_stage_tag "${s}"` with s=android and no arch -> `<repo>:cross-android-`
instead of the stage's real tag. Concrete break: run `build-cross-chain.sh
--from-stage base` (or any full chain) and let free space fall below
CROSS_DISK_GUARD_GB right after the base stage. `_chain_stage_disk_guard base`
-> `_disk_guard_protected_slugs base` returns `..._cross-android-,..._cross-
sdk-amd64,...` with `..._cross-compiler-amd64` MISSING.
`_disk_guard_pick_victim` is oldest-mtime-first, so the compiler slug (the
oldest, written first) is the first victim and gets `rm -rf`'d minutes before
the compiler stage rebuilds LLVM/GCC with `--cache-from type=local,src=<that
dir>` -> full cold LLVM/GCC rebuild (this repo's own notes: 50 min warm vs 11
h cold). The same corruption drops BOTH `base` and `cross-compiler-amd64` from
`_disk_guard_protected_slugs ''`, which is the list used by the in-stage
watchdog (`_chain_disk_watch_start`) and the runtime-lane entry gate
(`_chain_runtime_lane_disk_gate`) — so during the multi-hour runtime lane
those two slugs are the first things trimmed. The unit suite cannot catch
this: linux/scripts/tests/test-disk-guard.sh:54 stubs
`cross_stage_is_per_arch() { [ "$1" = "sdk" ] || [ "$1" = "media" ]; }`, which
does not touch `s`, and then asserts the CORRECT list including
`repo_img_compiler`. The test passes green while production returns a
different list.

**Evidence.**
Live proof from the build running right now — out/chain-media-
runtime.log:952892: `[INFO] [disk-guard] 113G free < 120G after stage android
— LRU-pruning cache exports in /home/bigjuicyjones/.cache/kata-buildcache
(protected: ghcr.io_kataglyphis_kataglyphis_beschleuniger_cross-android-)`
After `android` the only remaining stage is `runtime`, whose tag is empty
(stage-defs.sh:152), so the correct output is `protected: none`. Instead it
printed an arch-less `cross-android-` slug that does not exist on disk. Read-
only repro (sourcing the real functions, stubbing only
arch_list_to_words/stage_enabled): after base : ..._cross-android-,..._cross-
sdk-amd64,... <- cross-compiler-amd64 ABSENT after android : ..._cross-
android- empty (watch) : ..._cross-android-,..._cross-android-,..._cross-sdk-
amd64,... <- base AND cross-compiler-amd64 ABSENT Not present in
docs/refactoring-backlog.md or any refactoring-backlog-archive-*.md (grepped
for is_per_arch / protected slug / loop variable).

**Verifier's correction.**
The mechanism, the file:line, the repro values and the "unit test cannot catch
this" analysis are all correct as stated. Three refinements to the severity
framing: 1. The live log line offered as evidence (out/chain-media-
runtime.log:952892, after stage `android`) PROVES the leak but is itself
harmless. After `android` the only remaining stage is `runtime`, whose correct
protected list is genuinely empty, so protecting a phantom slug changed
nothing — the run correctly pruned cross-media-amd64 and proceeded. The damage
lives in the other two shapes of the bug, which this run never exercised (it
was a --from-stage media run). 2. The sharp damage is the
`completed_stage=base` case: it drops `<repo>:cross-compiler-amd64` — the
single most expensive slug to regenerate — from the protected list, and
because `_disk_guard_pick_victim` is oldest-mtime-first with no keep-floor in
`_chain_stage_disk_guard` (build-cross-chain.sh:510-519), a warm cache dir
makes that slug the first victim right before the compiler stage rebuilds
LLVM/GCC. This requires three conditions to co-occur: the chain actually runs
the `base` stage, the cache dir already holds a compiler slug from a prior
run, and free space drops below CROSS_DISK_GUARD_GB at that boundary. That is
the repo's normal warm-rebuild configuration, but it is a conditional loss,
not a guaranteed one — on a genuinely cold first run there is nothing to lose.
3. For the `''` list (the in-stage watchdog `_chain_disk_watch_start` and the
runtime-lane entry gate `_chain_runtime_lane_disk_gate`), `base` and `cross-
compiler-amd64` are indeed both dropped and are indeed the first victims by
mtime — but neither slug is consumed by the runtime lane itself, so the cost
there is the NEXT run's cold LLVM/GCC, not an in-run failure. Also cosmetic:
the phantom `cross-android-` entry appears twice in that list (once from the
`compiler` iteration, once from `runtime`). The one-line fix is `local
stage="$1" s` at stage-defs.sh:134; the test at test-disk-guard.sh:54 should
stop stubbing `cross_stage_is_per_arch` and source the real stage-defs.sh, or
the stub should be written with its own `for s in ...` so it reproduces
production's scoping.

### WJ. Disk-guard's anti-spin protection appends with a space to a comma-matched list, so an undeletable slug loops forever [medium]

`linux/scripts/build-cross-chain.sh:518`

**FIXED 2026-09-03.** Both anti-spin sites append with a comma now. The
behavioural half is worse than the entry said: a space-joined list protects
**nothing at all**, so `pick_victim` re-returns the same oldest slug rather
than merely failing to skip one. Guarded twice in `test-disk-guard.sh` — a
behavioural assertion that the space form protects nothing, and a structural
one on the chain itself, because a behavioural test alone rebuilds the string
and cannot notice the caller switching back.

**What breaks.**
`_chain_stage_disk_guard` has two `while` loops (phase 1 free-space, build-
cross-chain.sh:509-522; phase 2 total-size cap, :543-556). Both handle an
undeletable victim with the comment "An undeletable slug stays the LRU pick
forever: without this the loop spins for the rest of the run. Protect it and
move on." and then do `protected="${protected} ${victim}"` (lines 518 and 552)
— a SPACE separator. But `_disk_guard_pick_victim`
(linux/scripts/01-core/disk-guard.sh:54) tests `case ",${protected_csv}," in
*",${name},"*`, i.e. it only recognises COMMA-delimited entries. With
protected="a,b V" the string is ",a,b V," which does not contain ",V,", so V
is never excluded. Break: any slug under BUILDKIT_CACHE_DIR that `rm -rf`
cannot fully remove (a file written by a rootful/differently-mapped buildkitd,
an EPERM inside the tree, or a slug a concurrent local cache-export
recreates). The loop picks it, fails to delete it, "protects" it
ineffectively, re-measures free space (unchanged), and picks the same victim
again — forever. The chain hangs between two stages with no timeout and no
progress, spinning `rm -rf`/`du`/`df` and emitting the same `[disk-guard]
could not remove X; skipping it` warning, until a human kills it. Neither loop
has an iteration cap or a break, unlike `_disk_guard_trim_cache_export` (disk-
guard.sh:153-156) which correctly `break`s on the same condition.

**Evidence.**
linux/scripts/build-cross-chain.sh:516-518 and :550-552 append with a space;
linux/scripts/01-core/disk-guard.sh:50-54 matches only on commas
(`_disk_guard_protected_slugs` itself builds a comma list at disk-
guard.sh:77/81). No test covers the undeletable-victim path (grep for 'could
not remove'/'undeletable' in linux/scripts/tests/ returns nothing), and it is
absent from docs/refactoring-backlog.md and all refactoring-backlog-
archive-*.md.

**Verifier's correction.**
The claim is correct as written; two refinements to its severity model. (a)
The spin needs the victim to make no *measurable* progress, not merely to
survive. A partially-deletable victim (some children removable, some not)
keeps freeing space on each pass, so the loop makes progress for a while — but
once its removable content is exhausted and free space is still under
threshold, it wedges exactly as described. The "instant hang" case is a victim
nothing can be removed from (unreadable/untraversable slug dir), which is what
an EPERM/root-owned export looks like. (b) The claim's "a slug a concurrent
local cache-export recreates" sub-case does NOT spin: recreation bumps the
slug's mtime to now, moving it to the end of `ls -1tr`, so pick_victim
advances to an older slug. Drop that one; the EPERM/undeletable case is the
real one. Two things the claim understates, both worth carrying into the fix:
* The bug is a dead fix, not an oversight — commit 5337d6c4 exists solely to
prevent this spin, so the repo believes it is protected and is not. That also
means any log line `[disk-guard] could not remove X; skipping it` appearing
more than once for the same X in a run log is a live sighting of the wedge,
which is a cheap way to check the currently-running build. * The correct fix
is one character plus a belt-and-braces stop:
`protected="${protected}${protected:+,}${victim}"` at both build-cross-
chain.sh:518 and :552 (matching the comma format `_disk_guard_protected_slugs`
produces), and ideally also a `break` in the phase-1/phase-2 loops mirroring
`_disk_guard_trim_cache_export` (disk-guard.sh:153-156) so a systematically-
undeletable cache dir cannot hang the chain even if the protected list is
later refactored. A unit test asserting `_disk_guard_pick_victim` skips a
victim added by the guard's own append expression would have caught this and
does not exist.

## X2026-09-03. Second audit sweep — angles the first round did not cover

Six fresh lenses (supply chain, a meta-audit of the 48 test suites,
concurrency, docs-vs-code, the runtime image's contract, and a completeness
critic asked what BOTH rounds would miss), with the ten W-findings handed over
as an exclusion list so a variant counted as refuted. **8 survived, 8 were
killed by the verifier** — a 50% refutation rate, which is the point of
running it.

Read-only again: the RVA23 chain was building its riscv64 wrapper while this
ran.

### XK. GCC tarball SHA512 verification is skipped silently whenever a HEAD probe to gcc.gnu.org fails — exactly the outage the ftpmirror fallback exists for [high]

`linux/scripts/02-toolchain/build-gcc.sh:481`

**FIXED 2026-09-03.** Four holes, not one. Both proof probes now go through
`_gcc_probe_url` with an explicit `--timeout=20 -t 3`, and a probe that does not
answer is no longer read as "nothing to verify":

* an unreachable or absent `sha512.sum` now **aborts**, with
  `GCC_ALLOW_UNVERIFIED_TARBALL=1` as the explicit escape hatch. The file's own
  comment already claimed "no silent downgrade to an unverified build" — that is
  now true rather than aspirational;
* a `sha512.sum` with no entry for this tarball takes the same path, instead of
  warning and continuing;
* the `.sig` probe routes through `_gcc_gpg_require_or_warn`, so `GCC_REQUIRE_GPG=1`
  finally covers the case it most needed to — it previously returned 0 without
  consulting the knob at all;
* the probes had no timeout flags, so wget's defaults outlasted a short outage.

New suite `test-gcc-tarball-verification.sh` extracts the helpers (build-gcc.sh is
a top-level script, not a library) and stubs `wget` as unreachable. Reverting the
policy fails 3 of 6 assertions. Extracting `_gcc_probe_url` was not cosmetic: the
two probes had become identical and pushed the file's own duplication pair over
budget, so the gate asked for an owner and got one.

**What is NOT changed:** the mirror-first fetch order stays. The problem was never
that the bytes come from a mirror — it is that the proof was optional.

**What breaks.**
fetch_gcc_tarball (:469) downloads gcc-16.2.0.tar.xz from
MIRROR_TARBALL_URL=https://ftpmirror.gnu.org/gnu/gcc/gcc-16.2.0/ FIRST — a GNU
redirector that hands the request to an arbitrary volunteer mirror — with
gcc.gnu.org only as fallback. The sole unconditional integrity check on those
bytes is verify_gcc_sha512, and it is gated on `wget -q --spider "${SHA_URL}"`
against https://gcc.gnu.org/pub/gcc/releases/gcc-16.2.0/sha512.sum. That
spider is a HEAD request with NO --timeout/-t flags (every other wget in the
file passes `--timeout=20 -t 5`). Any non-200 — gcc.gnu.org unreachable or 5xx
(the single-host fragility the NET1 mirror was added for, per the comment at
:250-253), a CDN/WAF that answers HEAD with 403/405, or a DNS blip — makes the
function print `No sha512.sum found on server; continuing.` and `return 0`.
verify_gcc_gpg_signature (:381) then hits the identical spider against SIG_URL
on the same host and returns 0 the same way. Net result: the mirror's bytes
are extracted and configured/built (:520 onward) as the host GCC and all three
cross toolchains with ZERO integrity verification, and the whole 5-hour
chain's artifacts are produced by that compiler. The only trace in the log is
two innocuous 'not found on server' lines; the build exits 0 and every
downstream gate passes. This directly falsifies the in-code claim at :250-253
that the mirror is 'zero trust cost — sha512 verification below is against the
canonical server either way': the verification is conditional on the canonical
server being reachable, which is precisely what the mirror assumes it is not.

**Evidence.**
build-gcc.sh:481-484 `if ! wget -q --spider "${SHA_URL}"; then echo "No
sha512.sum found on server; continuing." >&2; return 0; fi` — contrast
:485-487, where a sha512.sum that DOES probe but fails to download is fatal
('refusing to continue unverified'), and :253 `# Try the GNU mirror redirector
first for the TARBALL (zero trust cost — sha512 verification below is against
the canonical server either way)`. MIRROR_BASE=https://ftpmirror.gnu.org/...
(:253), DOWNLOAD_BASE=https://gcc.gnu.org/... (:248),
SHA_URL=${DOWNLOAD_BASE}/sha512.sum (:256). The spider is the only wget in the
file without timeout/retry flags. Not present in docs/refactoring-backlog.md
or any docs/refactoring-backlog-archive-*.md (grepped for
gpg/sha512/spider/ftpmirror/build-gcc; the only hit, archive-2026-08-10:1511
'cache sha512.sum/.sig next', is a caching perf item).

**Verifier's correction.**
Confirmed, with three corrections and one strengthening. Accurate statement:
the GCC tarball is fetched mirror-first from the GNU redirector (build-
gcc.sh:469-472, MIRROR_TARBALL_URL) while both integrity proofs are canonical-
only (SHA_URL/SIG_URL, :256-257). Each proof is gated on an unauthenticated
availability probe of gcc.gnu.org — :481 for sha512.sum, :381 for the .sig —
and each probe failure is a `return 0` that continues the build. When
gcc.gnu.org does not answer those two probes with 200, the mirror's bytes are
extracted (:521) and built as the host GCC and all three cross toolchains with
no integrity check whatsoever, leaving only "No sha512.sum found on server;
continuing." and "No .sig found or accessible." in a log that exits 0.
Correction 1 — the "no --timeout/-t flags" argument is backwards. wget's
defaults are `--tries=20` and a 900s read timeout, so the bare spider is MORE
retry-persistent than the explicit `--timeout=20 -t 5` fetches, not less. A
momentary DNS blip is therefore not a realistic trigger. The realistic
triggers are (a) any non-2xx HTTP answer to the probe — a CDN/WAF or corporate
proxy that rejects HEAD with 403/405, a 429, a 5xx — which wget does not
retry, and (b) an outage that outlasts the default retries, i.e. precisely the
multi-minute gcc.gnu.org unavailability the NET1 mirror was added for.
Correction 2 — the GPG half is worse than described. :381-384 returns 0
WITHOUT calling `_gcc_gpg_require_or_warn` (:349), so `GCC_REQUIRE_GPG=1` —
the only knob that exists to make a skipped signature fatal, and one no file
in the repo sets — is structurally unable to fire on the unreachable-server
path. It covers only "gpg not installed" (:394) and "signer key unobtainable"
(:447). So there is no configuration of this repo, today, in which an
unreachable gcc.gnu.org fails the build. Correction 3 — scope the blast
radius. For Canadian-cross builders (HOST_TRIPLET set) a full gcc.gnu.org
outage would still abort loudly at :563-564, where
`contrib/download_prerequisites` pulls GMP/MPFR/MPC from the same host and
`die`s. The silently-unverified toolchain fully materializes in the non-
Canadian lanes (host GCC + the three cross toolchains, which use apt's
libgmp/libmpfr per :303-306) and, in the HEAD-rejection case, in every lane —
there the server is up, prerequisites download fine, and nothing anywhere in
the 5-hour chain notices. Also worth folding in: :489-491 is a second silent
skip on the same path — a downloaded sha512.sum with no matching
`gcc-<ver>.tar.xz` line warns and continues, so an upstream filename
convention change degrades to unverified as well. Finally, the realistic bad
outcome is substitution, not corruption: truncated or corrupt bytes die at
`tar -xf` (:522). What passes unnoticed is a volunteer mirror (or the
redirector) serving different-but-valid bytes, which then compiles every
artifact of the chain.

### XL. "missing cmake skips IREE with rc=1" leaves /usr/bin:/bin on PATH, so cmake is never missing — the _iree_check_prereqs skip path is never exercised and the case passes off a real host cmake failing on a stub source tree [medium]

`linux/scripts/tests/test-iree-wheelhouse-stages.sh:233`

**FIXED 2026-09-03** (`aac89983`). PATH is now just the stub dir, which holds the
git and ninja stubs; nothing in `build_iree_wheels` runs an external command before
the check. The case also asserts the REASON now, not only the return code — without
that, deleting the guard still returns 1 and the case still passes, which is exactly
how it went unnoticed. Proven in a sandbox copy: removing the cmake guard fails one
assertion, the reason one, while the rc assertion stays green on its own.

**What breaks.**
Delete (or invert) `command -v cmake >/dev/null 2>&1 || { warn "cmake absent;
skipping IREE riscv64 runtime wheel"; return 1; }` at
linux/scripts/05-frameworks/torch/build-app-wheelhouse.sh:781. The suite stays
fully green. Reason: the case runs `( PATH="${TMP}/nocmake:/usr/bin:/bin";
build_iree_wheels )`, and this host has /usr/bin/cmake and /bin/cmake
(verified: `command -v cmake` -> /usr/bin/cmake), so `command -v cmake`
SUCCEEDS. `ninja` and `git` are stubs copied into nocmake/ at line 100 and
`wheel_platform_tag` is a shell stub, so _iree_check_prereqs returns 0 on
every run. Control flow then falls through _iree_setup_compiler_cache ->
_iree_fetch_source (stub git builds a fake tree with no CMakeLists.txt) ->
_iree_build_host_stage, which invokes the REAL /usr/bin/cmake against that
tree; cmake errors, the `|| return 1` fires and build_iree_wheels returns 1.
`t_assert_eq "1" "${_rc}"` therefore passes for a completely different reason
than the one its name and message ("prereq failure must return 1") claim.
Real-world consequence of the undetected regression: in a stage where cmake
genuinely is absent, IREE no longer degrades to the documented one-line warn-
and-skip; it wipes and re-clones the tree (`rm -rf "${src_dir}"` in
_iree_fetch_source) and then dies in a cmake-not-found configure whose log
points nowhere near the cause.

**Evidence.**
test-iree-wheelhouse-stages.sh:233 sets PATH to
`${TMP}/nocmake:/usr/bin:/bin`; line 100 copies only git+ninja into nocmake/,
never a cmake shim, and never removes /usr/bin from the search path. build-
app-wheelhouse.sh:781 is the guard the case claims to exercise. `ls -la
/usr/bin/cmake /bin/cmake` -> both present (12556296 bytes, Mar 27). This is
exactly the "right answer for the wrong reason" class the repo already fixed
for this same file's five build call sites (docs/refactoring-backlog-
archive-2026-08-31.md:217-231: "asserting rc == 1 did not discriminate ... the
right answer for the wrong reason"); the fix there added `_no_packaging_diag`
to the five build cases (test-iree-wheelhouse-stages.sh:252, 262, 270, 279)
but never revisited the prereq case, which has no discriminating assertion at
all. Not in docs/refactoring-backlog.md or any refactoring-backlog-
archive-*.md (grepped for "missing cmake", "nocmake", "check_prereqs").

**Verifier's correction.**
Real, but it is a test-coverage defect only — trim the claimed real-world
consequence. Accurate statement: the case at test-iree-wheelhouse-
stages.sh:231-234 does not exercise _iree_check_prereqs at all. nocmake/
(:100) never shadows cmake and /usr/bin is left on PATH, so build-app-
wheelhouse.sh:781 succeeds; the asserted rc=1 is produced ~140 lines later by
_iree_build_host_stage:920 running the host's real /usr/bin/cmake against the
stub-cloned tree that has no CMakeLists.txt (the case inherits STUB_CROSS=1
from the preceding QNN case, so it takes the cross branch). Both prereq guards
are affected, not just cmake: /usr/bin/ninja exists too and nocmake/ contains
a ninja stub, so :782 is equally uncovered. The correct fix is to drop
/usr/bin:/bin from that PATH (or shim a failing cmake) and add a
discriminating assertion on the "cmake absent; skipping IREE" warn line, in
the same spirit as the _no_packaging_diag assertions added to the five build
cases. Two over-claims in the submission to correct: (1) the third prereq
guard IS genuinely covered — the "missing wheel platform tag" case at :236-240
sets STUB_WHEEL_PLATFORM="" and would go red if `[ -n "${wheel_platform}" ]`
were removed (the stub cmake then succeeds and the run returns 0), so only the
cmake/ninja `command -v` lines are untested; (2) the described consequence of
a removed guard is milder than stated — with cmake genuinely absent, execution
reaches `env -u … cmake …` at :920, whose ENOENT ("env: 'cmake': No such file
or directory") is NOT redirected to a log file and lands directly in the stage
output, followed by "IREE host stage failed in both COMPILER=OFF and
COMPILER=ON modes" and a fatal err in main(); the cost is a wasted rm -rf +
full recursive clone and a slightly indirect error, not a log "pointing
nowhere near the cause". Severity is low-to-medium: cmake is present in every
stage that runs build-app-wheelhouse.sh, so no shipped artifact is at risk
today; what is real is that the suite advertises a skip-path assertion it does
not make, and a refactor of _iree_check_prereqs would be mutation-invisible.

### XM. Two test-guard-helpers.sh cases end in `t_assert_ok true` after a subshell whose exit status is thrown away — they cannot fail, so source_vendor's nounset window and first_match's missing-dir contract are unprotected [medium]

`linux/scripts/tests/test-guard-helpers.sh:57`

**FIXED 2026-09-03** (`dafd45db`). Both cases capture `$?` straight after the
subshell. **The first fix was no fix:** wrapping the subshell in `if ... then`
suppresses errexit inside it, so the very abort under test could not happen — the
suite stayed green with `first_match`'s `|| true` removed. Caught by mutating.
Proven in a sandbox copy of 01-core: removing `|| true` fails exactly one
assertion, dropping `source_vendor`'s `set +u` fails two.

**What breaks.**
Rewrite `source_vendor` (linux/scripts/01-core/guard-helpers.sh:45-55) to drop
its `set +u` window — i.e. regress it to the plain `. "${_f}"` the helper
exists to replace. The case at :55-57 runs `( set -u; source_vendor
"${_tmp}/vendor.sh"; [ "${VENDOR_SAW}" = "unset-ok" ] )` where vendor.sh
references `${SOME_DEFINITELY_UNSET_VAR}`; the subshell would die with
"unbound variable" and exit non-zero — but the file sets only `set -u` (line
4), not `set -e`, so a failing subshell does not abort the suite, and the next
statement is the literal `t_assert_ok true`, which runs `true` and always
passes. Identical shape at :31-33 for `first_match` on a missing directory:
make first_match drop its trailing `|| true` (guard-helpers.sh:24) and the `(
set -e; ... )` subshell aborts, unnoticed. Both cases are the pre-migration
contract freeze for the ~426 raw call sites the module is meant to absorb (its
own header, guard-helpers.sh:6-10), and it is already sourced live at
01-core/common.sh:36 and 03-media/core/common.sh:107 — so a silent regression
here is inherited by every site the migration touches.

**Evidence.**
test-harness.sh has no facility that captures a bare subshell's status;
`t_assert_ok true` (lines 33 and 57) evaluates `true` and can only pass. The
suite's shell options are `set -u` at line 4 — no errexit — so `( ... )`
exiting non-zero is discarded silently. `grep -rn "t_assert_ok true" tests/`
returns exactly these two standalone uses plus one at :47 that IS
discriminating (it sits in the `else` arm of an `if probe sh -c 'exit 3'`,
whose `then` arm asserts a failure). guard-helpers.sh currently has ZERO
production call sites (`grep -rn -e '\bfirst_match ' -e '\bsource_vendor ' -e
'\bcsv_each ' linux/scripts --include='*.sh'` outside tests/ matches only the
doc comments in the module itself), which is why the damage is latent rather
than live today. Not recorded: grep for "guard-helpers", "source_vendor",
"first_match", "t_assert_ok" across docs/refactoring-backlog.md and every
refactoring-backlog-archive-*.md returns only the 2026-08-10 archive's plan to
CREATE these helpers, nothing about the suite.

**Verifier's correction.**
Record it in this narrowed form only: ONE case, not two, is an unprotected
contract. test-guard-helpers.sh:31-33 is the sole coverage of first_match's
missing-directory contract, and its assertion cannot fail: the `( set -e;
r="$(first_match "${_tmp}/does-not-exist" -name '*')"; [ -z "$r" ] )`
subshell's exit status is discarded (the file sets only `set -u` at :4 — no
errexit, no ERR trap — and run-tests.sh:20 runs each suite as plain `bash`),
and the next statement is the literal `t_assert_ok true`, which per test-
harness.sh:67-70 executes `true`. Deleting the `|| true` from guard-
helpers.sh:24 leaves the suite fully green. The other three first_match cases
(:19, :24, :28) all target an existing directory where find returns 0, so none
of them substitute for it. Fix: capture the status, e.g. `( set -e; ... );
t_assert_eq "$?" "0"`, or assert via `t_assert_ok bash -c '...'`. The
source_vendor half of the claim is WRONG and must be dropped. :55-57 is indeed
tautological, but the nounset window is already covered by the next case at
:59-61: under `set -u` the unbound-variable error kills that command
substitution before its `case "$-"` runs, so a source_vendor regressed to a
plain `. "${_f}"` yields an empty `_restored` and fails t_assert_eq at :61
(simulated both ways: regressed => empty, correct => "yes"). :63-65 and :67-69
cover the no-force-`-u` and rc-propagation contracts. So :55-57 is redundant,
not a hole — worth deleting or converting for tidiness, but it is not a gate
failure. Severity is LATENT, not live. guard-helpers.sh is sourced at
01-core/common.sh:36 and 03-media/core/common.sh:107, but it has zero call
sites anywhere in linux/ (every match outside tests/ is a doc comment or
prose), exactly as guard-helpers.sh:6-10 says — the ~426-site migration is
rebuild-gated and has not happened. No current build can go wrong from this;
the cost is that the pre-migration contract freeze for first_match's `|| true`
is not actually frozen.

### XN. --no-push android artifact handoff: producer writes `android-artifacts-<arch>`, consumer reads `android-artifacts/<arch>` [high]

`linux/scripts/build-cross-chain.sh:162`

**FIXED 2026-09-03.** `runtime_artifact_context_dir` joins with `-` now, matching
what `cross_stage_context_dir` writes. Verified both sides by extracting the REAL
composers rather than re-implementing them: producer and consumer now name the
same directory. The consumer side was the right one to change — three production
callers use the `<stage>-<arch>` convention, and this join has exactly one user.

**What breaks.**
Run the officially-supported full no-push validation chain: `bash
linux/scripts/build-cross-chain.sh --no-push --target-arches
amd64,arm64,riscv64` (allowed since 2026-08-30 by _chain_no_push_guard, build-
cross-chain.sh:286). The android stage exports its OCI layout via
`cross_stage_context_dir android-artifacts "${arch}"` (cross-stage-
build.sh:502), and cross_stage_context_dir (cross-stage-build.sh:109-113)
composes `${CROSS_CONTEXT_WORKDIR}/${stage}${arch:+-${arch}}` ->
`<WD>/android-artifacts-arm64`. run_runtime_stage then exports
ARTIFACT_CONTEXT_ROOT=`<WD>/android-artifacts` (build-cross-chain.sh:162), and
runtime_artifact_context_dir (context-management.sh:209) composes
`${ARTIFACT_CONTEXT_ROOT%/}/${arch}` -> `<WD>/android-artifacts/arm64`. That
directory never exists. runtime_artifact_context_ref (context-
management.sh:219) fails its `index.json`/`oci-layout` check, prints '[ERROR]
Missing OCI artifact context for arm64' and returns 1 — but
runtime_build_package_image runs under run_parallel_arch_loop's disabled-
errexit extent, so the empty capture flows straight into
`build_args+=(--build-context "runtime_artifact=")` (runtime-build-fns.sh:289)
and every arch's package build dies on a malformed build-context, hours into
the run. Net effect: the no-push lane can never reach the runtime stage, and
when the guard-rail is bypassed the package would copy from the stale
published cross-android tag instead of the image just built — exactly the
2026-08-08 stale-parent bug backlog item C claimed to close.

**Evidence.**
Simulated both helpers verbatim: producer -> /WD/android-artifacts-arm64,
consumer -> /WD/android-artifacts/arm64. The mismatch was introduced in
8c97cdd8 ('backlog sweep 2026-08-30: close F1/F2/C'); its own comment at
build-cross-chain.sh:158 asserts the exporter wrote `<cross workdir>/android-
artifacts/<arch>`, which cross_stage_context_dir does not do.
CHANGELOG.md:1322, docs/linux-cross-builds.md:175 and docs/refactoring-
backlog-archive-2026-08-30.md:64 all document the slash form, so the repo's
claim and the code disagree. test-cross-oci-handoff.sh:180-183 greps only
cross-stage-build.sh for the raw read, so it cannot see the orchestrator side.

**Verifier's correction.**
The mechanism is confirmed, but three parts of the claim need correcting. 1.
WRONG COMMIT. The break was NOT introduced by 8c97cdd8. That commit
(2026-08-30) wrote the correct slash form as a literal: `local
artifact_dir="${CROSS_CONTEXT_WORKDIR}/android-artifacts/${arch}"`, matching
its own comment and all the docs. The regression is commit 3be6b427
(2026-09-01, "cross-chain: the --no-push OCI handoff never activated"), which
replaced that literal with `artifact_dir="$(cross_stage_context_dir android-
artifacts "${arch}")"` to fix an unrelated `set -u` hazard, not noticing that
`cross_stage_context_dir` joins the arch with a DASH
(`${stage}${arch:+-${arch}}`, cross-stage-build.sh:113) while the consumer
joins with a SLASH (`${ARTIFACT_CONTEXT_ROOT%/}/${arch}`, context-
management.sh:209). The consumer side was never touched by 3be6b427. So build-
cross-chain.sh:162 is not the defect — it is the half that still matches the
documentation; the defect is at linux/scripts/01-core/cross-stage-
build.sh:502. 2. THE TEST IS WORSE THAN "BLIND". test-cross-oci-
handoff.sh:180-183 does not merely fail to see the orchestrator side; it
asserts `grep -c 'CROSS_CONTEXT_WORKDIR}/android-artifacts' cross-stage-
build.sh` equals 0, i.e. it actively forbids the correct 8c97cdd8 form and
pins the broken helper call. Restoring the slash path by reverting to the
literal turns that assertion red. 3. NO STALE-TAG PATH ANY MORE. The claim's
second half ("when the guard-rail is bypassed the package would copy from the
stale published cross-android tag") does not occur on current HEAD.
`runtime_use_local_artifact_context` is true whenever `ARTIFACT_CONTEXT_ROOT`
is non-empty, and since 3be6b427 mints `CROSS_CONTEXT_WORKDIR` eagerly in
`main()` the orchestrator always sets it under `--no-push`. So the registry-
fallback branch (runtime-build-fns.sh:290-294) is never taken; the run always
takes the hard-failure branch instead. The failure is also loud, not silent:
`[ERROR] Missing OCI artifact context for <arch>: <dir>` is printed before the
malformed `--build-context` is assembled. The real cost is a full `--no-push`
validation chain (base..android, multiple hours across three arches) dying at
its final stage, plus the wrapper-smoke gate at runtime-build-fns.sh:367-374
failing the same way. Accurate statement: on HEAD the `--no-push`
android->runtime artifact handoff is path-mismatched — the exporter writes
`<cross workdir>/android-artifacts-<arch>` while the runtime helper looks in
`<cross workdir>/android-artifacts/<arch>` — so a full `bash
linux/scripts/build-cross-chain.sh --no-push --target-arches
amd64,arm64,riscv64` cannot complete its runtime stage. One-line fix either
way: make the exporter use the slash form (and drop/invert the test at test-
cross-oci-handoff.sh:180-183), or set
`ARTIFACT_CONTEXT_ROOT="${CROSS_CONTEXT_WORKDIR}/android-artifacts"` -> a
dash-joined root the consumer can compose. The exporter side is preferable,
since CHANGELOG.md:1322, docs/linux-cross-builds.md:175-176 and
docs/refactoring-backlog-archive-2026-08-30.md:64 all document the slash
layout.

### XO. parallel_loop_harvest keys on pin.* files only, so --no-push --parallel-archs loses every *_BUILT_THIS_RUN flag [medium]

`linux/scripts/01-core/cross-stage-build.sh:521`

**FIXED 2026-09-03.** The harvest keys on BOTH flag kinds. It iterated `pin.*`
alone with the `built.*` handling nested inside, so a `built.` with no `pin.`
beside it was never seen — which is the whole `--no-push` path, where a worker
has no digest to write. Three cases cover it: the push path harvesting both, a
built flag alone, and an empty dir not tripping on the unmatched glob.

**What breaks.**
Run `build-cross-chain.sh --no-push --parallel-archs` (full chain from base).
Each per-arch worker is a background subshell, so its array writes are lost to
the parent; that is why the workers persist state to PARALLEL_LOOP_FLAGDIR. On
the push path the worker writes BOTH `pin.<stage>.<arch>` and
`built.<stage>.<arch>` (cross-stage-build.sh:421-422). On the push_flag=0 path
it writes ONLY `built.<stage>.<arch>` (cross-stage-build.sh:484) — there is no
pin to capture. parallel_loop_harvest's loop iterates `"${flagdir}"/pin.*.*`
and reads the built flag only from inside that loop body (line 532-536), so
with zero pin files the glob matches nothing and ANDROID_BUILT_THIS_RUN stays
empty in the orchestrator. run_runtime_stage then calls
cross_stage_ensure_parent_available runtime, whose built-this-run short-
circuit (stage-defs.sh:402-409) misses, and it executes `nerdctl pull
--platform linux/amd64 ghcr.io/.../kataglyphis_beschleuniger:cross-
android-<arch>` for all three arches — re-downloading the last PUBLISHED
android images (tens of GB each over the ~4-5 MB/s uplink noted in the push-
compression comment) and re-pointing the local cross-android-<arch> tags at
stale content, on a run whose entire purpose was to validate locally built
bytes without touching the registry. The sequential path is unaffected because
cross_stage_run writes `_local_built_flag["${arch}"]=1` directly in the parent
(cross-stage-build.sh:478-482), so the guard the comment there names ('without
it the runtime handoff pulls the STALE published parent over the image this
run just built') is silently disarmed only under --parallel-archs.

**Evidence.**
cross-stage-build.sh:483-485 writes built.* with no pin.*; cross-stage-
build.sh:521 `for f in "${flagdir}"/pin.*.*` is the sole iteration; the built-
flag harvest at 532-536 is nested inside that loop. Same loss applies to
`build-sdk-artifacts.sh --parallel-archs` without --push, which passes push=0
(build-sdk-artifacts.sh:88). Archive item R2 ('BUILT_THIS_RUN in the local
build path') added the line-478 write but never extended the harvest.

**Verifier's correction.**
Accurate statement: under `--no-push --parallel-archs`, ANDROID_BUILT_THIS_RUN
is lost, so the runtime stage pulls the last PUBLISHED android images — but it
does not ship them in the default flow. parallel_loop_harvest
(linux/scripts/01-core/cross-stage-build.sh:519-539) iterates only
`"${flagdir}"/pin.*.*` (line 521) and reads the built flag from inside that
loop (533-537). The push path writes both flag files (421-422); the
push_flag=0 path returns at 486 before _cross_stage_run_capture_pin and writes
only `built.<stage>.<arch>` (484). With zero pin files the glob never matches,
so under --no-push + --parallel-archs no built flag is harvested and
ANDROID_BUILT_THIS_RUN stays empty in the parent. The sequential path is
unaffected (478-482 writes the parent array directly). Consequence, corrected:
1. cross_stage_ensure_parent_available (stage-defs.sh:390-419), called
unconditionally at build-cross-chain.sh:141, misses its skip at 403-406 and
runs `nerdctl pull --platform linux/amd64 ...:cross-android-<arch>` (line 418)
for all three arches — re-downloading the previously published android images
on a run that build-cross-chain.sh:262-263 documents as never consulting the
registry, and clobbering the locally built `cross-android-<arch>` tags with
stale published content. That is precisely the outcome the comment at 475-476
says line 478 exists to prevent. 2. The runtime lane itself is NOT poisoned in
the default configuration: CROSS_NO_PUSH=1 sets ARTIFACT_CONTEXT_ROOT/MODE=oci
(build-cross-chain.sh:161-165), runtime_use_local_artifact_context (context-
management.sh:199-201) is true, and runtime_build_package_image passes
`--build-context runtime_artifact=<oci layout>` (runtime-build-fns.sh:284-289)
pointing at the layout exported from this run's android image (cross-stage-
build.sh:496-503) before the pull. So the package/wrapper still get locally
built bytes; the cost is wasted bandwidth/disk plus corrupted local tags, not
a wrong artifact. 3. It becomes a wrong artifact only with
CROSS_LOCAL_CONTEXT_HANDOFF=0 + CROSS_NO_PUSH_FORCE=1: the workdir is never
created, build-cross-chain.sh:166-167 unsets ARTIFACT_CONTEXT_ROOT, and
runtime-build-fns.sh:292-294 falls back to the mutable android tag the pull
just re-pointed at the previous run's image. 4. A failing pull is swallowed:
run_runtime_stage runs under `||` (build-cross-chain.sh:355) with errexit
disabled, so a non-zero `run ... pull` neither aborts nor warns. 5. Drop the
sdk half of the claim: build-cross-chain.sh:141 is the only caller of
cross_stage_ensure_parent_available, so SDK_BUILT_THIS_RUN has no consumer and
its loss under `build-sdk-artifacts.sh --parallel-archs` is harmless. Fix
shape: iterate `built.*.*` as well (or instead), or have the no-push path
write a placeholder pin file the harvest can key on.

### XP. cross-build-verification.md still calls the TVM smoke "report only" — the chain arms EXP_TVM unconditionally, so a TVM-less image now blocks the manifest [high]

`docs/cross-build-verification.md:180`

**HALF DONE 2026-09-03.** The doc row is corrected: it now says the gate is a HARD
assert armed by default from `versions.env` `TVM_REF`, that there is no escape
hatch, and that a TVM-less lane means removing the pin rather than expecting a
warning. **The worse half is deliberately left**: `Dockerfile.media:562-565` still
promises "BEST-EFFORT on EVERY arch … it can never break the media build"
directly above the RUN whose else-branch ships a TVM-less image as a warning.
A comment-only edit there is cache-neutral (BuildKit keys on parsed instructions,
not comment text), but it was not worth touching Dockerfile.media while the
chain's publishing lane was mid-flight for zero immediate gain. First item of
the next window, together with naming the real blocking call —
`smoke-runtime-image.sh:358-369` via `build-runtime-manifest.sh:310`, not the
in-build smoke.

**What breaks.**
A media build ships without TVM (the code itself anticipates this: smoke-
torch-venv.sh:298 prints "not importable (best-effort; media build shipped
without it)"). The wrapper smoke instead appends "tvm NOT IMPORTABLE but
EXP_TVM set" to fails, the per-arch wrapper smoke goes red in build-runtime-
manifest.sh, and :latest-cross is never published — at the very end of a
multi-hour chain. The operator opens the escape-hatch table, reads that TVM is
"report only — best-effort by design" and that EXP_TVM is an opt-in, and goes
hunting for whoever exported it. Nobody did: the smoke sets it from
versions.env on every run. Same trap in reverse for anyone who deliberately
drops TVM from a lane expecting a warning.

**Evidence.**
DOC docs/cross-build-verification.md:180 — "| TVM presence/version per arch |
`smoke-torch-venv.sh` (report only — TVM is best-effort by design) |
`EXP_TVM=<version>` turns the report into a hard pin assertion |". CODE
linux/scripts/06-packaging/smoke-torch-venv.sh:97 — inside
assert_pinned_versions, run on every image: `EXP_TVM="$(_stv_vpin
"${versions_env}" TVM_REF)" \`, with versions.env resolved at :76 from
/opt/scripts/core/versions.env (baked into the image) and TVM_REF=v0.26.0
always present (linux/scripts/01-core/versions.env:118). The same file's own
comment at :280 already says the opposite of the doc: "# TVM is now a HARD
assert (EXP_TVM set from versions.env TVM_REF)." The reassuring best-effort
branch at :297-298 only runs when EXP_TVM is empty, which the chain never
produces. Closed as LOG34 in docs/refactoring-backlog-
archive-2026-08-27.md:733 ("EXP_TVM is now …") without updating this table.

**Verifier's correction.**
CONFIRMED, with four refinements. WHAT IS EXACTLY RIGHT: docs/cross-build-
verification.md:180 sits in a table whose stated premise is "Each hard gate
has ONE explicit, documented escape hatch". For TVM it says the gate is
"report only — TVM is best-effort by design" and lists `EXP_TVM=<version>` in
the OPT-IN column. Since LOG34 (2026-08-30) the code sets EXP_TVM itself on
every run from versions.env TVM_REF (smoke-torch-venv.sh:97), so the row is
inverted twice over: the gate is armed by default, and the column that should
name an escape hatch names the knob that arms it. There is no documented way
to ship a TVM-less image. REFINEMENT 1 — the doc is not the only stale copy,
and the second one is worse. linux/Dockerfile.media:562-565 carries the same
claim ("BEST-EFFORT on EVERY arch ... it can never break the media build.
Visibility (NOT a gate — TVM stays best-effort)") directly above the RUN at
:568-574 whose else-branch ships a TVM-less media image as a non-fatal
WARNING. Producer promises non-fatal; consumer hard-fails hours later. Fixing
only the doc leaves the more misleading of the two in place. REFINEMENT 2 —
name the real gate, not the in-build one. The blocking call is smoke-runtime-
image.sh:358-369 (check_ml_version_pins, STV_ASSERT_ONLY=1) reached from
build-runtime-manifest.sh:310; `set -euo pipefail` at :2 kills the run before
create_manifest at :315. Dockerfile.package:395 runs the same script in-build
but SKIPs (no /opt/venv there), so the failure genuinely lands at the end of
the chain, exactly as claimed. REFINEMENT 3 — a third stale statement, and one
of the two must be wrong. Dockerfile.torch:58-60 states "TVM is missing from
all three shipped images because the media stage produces no tvm wheel (tvm-
python.sh's verdict)". If that were still true, the armed assert would fail
every 3-arch build. LOG34 (archive-2026-08-27:733, closed 2026-08-30) says the
opposite was proved on all three arches. That comment predates LOG34 (ORPHAN-
PINS, 2026-08-23) and should be re-measured or deleted alongside the doc row;
whoever fixes the table should check which is current before writing "TVM
ships on all three". REFINEMENT 4 — a disarm exists but it is not the one
documented, and it is far too broad to sell as an escape hatch. Setting
VERSIONS_ENV to a path that does not exist makes assert_pinned_versions fall
back to ${_SCRIPT_DIR}/../01-core/versions.env, which is
/opt/scripts/01-core/versions.env in the image and does not exist (the file is
at /opt/scripts/core/). The SKIP guard at :80-83 needs BOTH versions.env and
uv.lock missing, and uv.lock is present, so the run continues with EVERY EXP_*
pin empty — torch, torchvision, onnx, litert, genai, opencv-major all silently
unasserted. The honest fix is a TVM-specific opt-out (e.g. STV_TVM_OPTIONAL=1,
or reverting to setting EXP_TVM only when a caller exports it) plus rewriting
the table row to say the gate is armed by default; do not document the
VERSIONS_ENV path as the hatch.

### XQ. The only gate that exercises entrypoint.sh's env sourcing asserts two variables the image ENV already sets, so "gstreamer-env.sh sourcing regressed" is undetectable [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:133`

**FIXED 2026-09-03.** The gate asserted `GST_PLUGIN_PATH` and `VULKAN_SDK` were
SET — and the image ENV sets both on its own, which was measured in the published
image before anything changed: bypassing the entrypoint entirely still answers
yes to both. So "the entrypoint's sourcing regressed" was undetectable.

It now asserts what ONLY the entrypoint provides, established by diffing the
container env with and without it: the multiarch plugin dir inside
`GST_PLUGIN_PATH`, and a `VULKAN_SDK` resolved past `/opt/vulkan/active`. Proven
against the shipped image — with the entrypoint `gstma=yes vkres=yes`, bypassing
it `gstma=no vkres=no`, where the old assertion said "set" both times.

The verdict moved into `_boot_verdict`, a pure function in the file's own
established shape, so the reasoning is unit-testable without a container — which
is how the inert version would have been caught. Four cases, plus a mutation
restoring the old `gst=set` assertion, which bites.

`test-smoke-arch-parity.sh` went red on this and was RIGHT to: its fake entrypoint
exported `GST_PLUGIN_PATH=/fake/gst`, while its own comment promised "the env the
entrypoint is supposed to have exported". The fixture now carries the real shapes.

**What breaks.**
State: the shipped image loses its entrypoint env layer -- e.g.
Dockerfile.torch:110's `COPY ... gstreamer-env.sh /usr/local/bin/gstreamer-
env.sh` is dropped/renamed, or gstreamer-env.sh exists but aborts partway
(entrypoint.sh:13-25 `_safe_source` does `source "$f"` and then `return 0`
UNCONDITIONALLY, and it is always invoked as `_safe_source ... || echo ...`, a
`||` list, so bash suspends errexit inside the function body -- a mid-file
failure neither kills PID 1 nor trips the `|| echo "Warning: ... not found or
not sourced"` arm). Every container then starts WITHOUT
`/opt/gstreamer/share/pkgconfig` and `/opt/gstreamer/lib/pkgconfig` on
PKG_CONFIG_PATH, without `/opt/gstreamer/lib/gstreamer-1.0` on GST_PLUGIN_PATH
and without `/opt/gstreamer/lib/girepository-1.0` on GI_TYPELIB_PATH --
exactly the non-multiarch spellings the ENV block does not carry. Wrong
outcome: check_default_entrypoint_boot still prints `PASS default
ENTRYPOINT+CMD boot: BOOT uid=1001 gst=set vulkan=set`, because the probe at
line 127 reads `${GST_PLUGIN_PATH:+set}` and `${VULKAN_SDK:+set}`, and BOTH
are baked unconditionally into the image config by Dockerfile.package:235 and
:221 -- they are non-empty in every container whether or not the entrypoint
ran at all. The `2>/dev/null` on line 129 additionally discards
entrypoint.sh's own warning line, so the last observable trace is thrown away
too. Only the rc==42 half of this probe is real; the env half cannot fail for
the reason its own fail message names.

**Evidence.**
smoke-runtime-image.sh:127 `'echo "BOOT uid=$(id -u)
gst=${GST_PLUGIN_PATH:+set} vulkan=${VULKAN_SDK:+set}"'`; :129 `|
"${NERDCTL_BIN}" run --rm -i ... "${image_tag}" 2>/dev/null)`; :133-134 `elif
! printf '%s' "${out}" | grep -q "gst=set"; then fail "...the entrypoint
exported no GStreamer env ... gstreamer-env.sh sourcing regressed"`. The two
variables come from Dockerfile.package:235 `GST_PLUGIN_PATH="${GSTREAMER_PREFI
X}/lib/multiarch/gstreamer-1.0:${LIBCAMERA_PREFIX}/lib/gstreamer-1.0"` and
:221 `VULKAN_SDK=/opt/vulkan/active`. entrypoint.sh:20-22 `source "$f"` / `[
"${_ss_had_u}" = "1" ] && set -u` / `return 0`; call sites entrypoint.sh:28
and :30. Confirmed live in out/build-logs/cross-chain-wave6b.log:3273193 and
runtime-retry2.log:2952029 -- all three arches print the identical constant
`gst=set vulkan=set`. A gate that would actually see the regression must read
something the ENV does not pre-set (e.g. `${GSTREAMER_PREFIX}/lib/pkgconfig`
inside PKG_CONFIG_PATH).

**Verifier's correction.**
Accurate statement, with two overstatements in the claim trimmed: CONFIRMED
CORE: `linux/scripts/06-packaging/smoke-runtime-image.sh:133-134` is the only
assertion in the tree that claims to detect a gstreamer-env.sh sourcing
regression, and it cannot fail for that reason. It tests
`${GST_PLUGIN_PATH:+set}` (composed at :127), but GST_PLUGIN_PATH is baked
unconditionally into the image config by `linux/Dockerfile.package:235` and
inherited by the wrapper through the config-preserving OCI-layout handoff
(`linux/scripts/01-core/context-management.sh:243`), so it is non-empty in
every container whether or not `/usr/local/bin/gstreamer-env.sh` was ever
COPY'd (Dockerfile.torch:110) or sourced. The `2>/dev/null` at :129
additionally throws away entrypoint.sh's own `Warning: … not found or not
sourced` line (entrypoint.sh:29), the last observable trace. A gate that could
actually discriminate must read something only gstreamer-env.sh adds — e.g.
`${GSTREAMER_PREFIX}/share/pkgconfig` inside PKG_CONFIG_PATH — or simply
assert the file exists and is non-empty. TRIM 1 — "asserts two variables":
only one is asserted. `vulkan=set` is printed but never grepped; the sole
predicate is `grep -q "gst=set"`. (Both are ENV-constant, so neither could
discriminate, but the assertion is single.) TRIM 2 — blast radius is smaller
than "every container then starts without …". The paths gstreamer-env.sh adds
are, in this image, near-duplicates of the ENV spellings:
`${GSTREAMER_PREFIX}/lib/multiarch` is a symlink to the real libdir
(`linux/scripts/03-media/build/gstreamer/common/build-gstreamer-stage.sh:51`,
`linux/scripts/03-media/runtime/configure-runtime.sh:76-80`, repaired again at
`linux/scripts/06-packaging/setup-package-image.sh:392-398`), so the ENV's
`lib/multiarch/{gstreamer-1.0,pkgconfig,girepository-1.0}` already resolve to
the same directories gstreamer-env.sh would prepend, and ENV
PATH/LD_LIBRARY_PATH already carry `${GSTREAMER_PREFIX}/bin` and both `lib`
and `lib/multiarch`. The only genuinely unique contribution is
`${GSTREAMER_PREFIX}/share/pkgconfig` on PKG_CONFIG_PATH. So a lost sourcing
layer would likely be latent rather than immediately breaking — which is
precisely why nothing else would catch it, and why the inert gate matters: the
regression would ship green and stay invisible until a consumer needed the
non-multiarch pkgconfig spelling. Bottom line: real, but it is a "gate cannot
fail" / dead-assertion defect (correctly-worded fail message attached to a
predicate that is a constant), not an imminent runtime breakage. The rc==42
half of the probe at :131 is genuine and does its job.

### XR. The curated dependency inventory is only checked in one direction, so a shipped component with no deps.json entry is invisible to every gate — IREE and PyAV ship in :latest-cross and appear in none of deps.json, the licence pages, or the curated SBOM [medium]

`docs/scripts/deps_table.py:34`

**CONTENT HALF DONE 2026-09-03, structural half still open.** IREE and PyAV now
have entries in `docs/deps/deps.json`, and the curated SBOM (100 packages) and
both website licence pages regenerate clean. Licences were read from the
projects' own LICENSE files rather than assumed: IREE is Apache-2.0 **WITH
LLVM-exception** (PyPI metadata says plain Apache-2.0, which is less precise than
an SBOM should be), PyAV is BSD-3-Clause (confirmed by the endorse-or-promote
clause). **What is NOT fixed is the reason it happened:** `resolve_dep_version`
still only raises for the reverse case, so the next source-built component added
without an entry is just as invisible. That needs a shipped-component-to-entry
check with a frozen baseline, the same shape as the WD fix, and it needs a
decision first about which `versions.env` keys count as shipped components --
most of the 115 are build tools and SHAs. AGENTS.md's claim that a missing entry
fails the build stays false until then.

**What breaks.**
Add a source-built component to versions.env and build it into the image
without touching docs/deps/deps.json. `resolve_dep_version` raises only for
the reverse case (a deps.json entry naming a versions.env key that no longer
exists), and every consumer — sync_versions.py's deps-table check
(docs/scripts/sync_versions.py:417), generate_sbom.py --check, generate-
website-licenses.py — is generated FROM deps.json, so a missing entry produces
no diff and all four preflight docs gates (version-snapshot, doc-links, doc-
dupes, sbom) stay green forever. This already happened twice: IREE
(versions.env:152 `IREE_VERSION=v3.11.0`, integrated 2026-07-14, riscv64
runtime built from source, iree-base-runtime/-compiler shipped and asserted by
the runtime smoke) and PyAV (versions.env:213 `PYAV_VERSION=18.1.0`, built
from source in Dockerfile.media:793 `FROM ffmpeg AS pyav` and installed into
/opt/venv; measured as `av 18.1.0` in the shipped image, backlog §G). Both are
absent from docs/deps/deps.json, from the generated table in docs/third-party-
licenses.md, from linux/webserver/license-
assets/documents/footer/openSourceLicenses{En,De}.md (the page the webserver
actually serves) and from docs/deps/sbom-curated.spdx.json — so the published
inventory and SBOM describe an image that is not the one shipped. PyAV
additionally links the FFmpeg this repo configures with --enable-gpl --enable-
version3 (docs/third-party-licenses.md:147), i.e. the omission lands on the
copyleft side the curated half exists to cover.

**Evidence.**
deps_table.py:34-45 (the only completeness contract, one-directional, with a
comment naming just the renamed/removed-var case); generate_sbom.py:8-26
states the curated half's whole purpose is source-built components an image
scanner cannot see; AGENTS.md:1690-1693 claims "A new component needs an entry
in docs/deps/deps.json … or the build fails", which no code enforces.
Verified: `grep -i iree docs/deps/deps.json` → no match; `grep -ic iree
docs/deps/sbom-curated.spdx.json` → 0; the same for pyav; a dump of all 98
deps.json entries lists ArmNN, TVM, LiteRT-LM, VVdeC, GenAI etc. but neither
IREE nor PyAV.

**Verifier's correction.**
CONFIRMED, with two overstatements trimmed. Accurate statement: the deps.json
completeness contract runs in one direction only.
`docs/scripts/deps_table.py:34` raises for a deps.json entry whose `var`
vanished from versions.env; nothing checks the reverse, so a component that
ships without a deps.json entry is invisible to `sync_versions.py:417`,
`generate_sbom.py --check`, `generate-website-licenses.py` (including its
`check_obligations_are_discharged` at line 158, which also iterates deps.json
entries only) and all four preflight docs gates, which stay green forever.
`compare_sbom.py` is the only script that reads a real scan and it always
`return 0` (line 141), so it is a report, not a gate. `AGENTS.md:1688-1690`
claims a new component needs a deps.json entry "or the build fails"; no code
enforces that. Two live instances: IREE (versions.env:152, built per-arch and
asserted by `smoke-runtime-image.sh:388`) and PyAV (versions.env:213,
`Dockerfile.media:793`, wheels collected at Dockerfile.media:1105) — absent
from deps.json, from the generated table in docs/third-party-licenses.md, from
the served `linux/webserver/license-
assets/documents/footer/openSourceLicenses{En,De}.md`, and from
docs/deps/sbom-curated.spdx.json. Correction 1 — the SBOM half of the impact
is weaker than claimed. The curated SBOM's stated scope
(generate_sbom.py:8-14) is components an image scanner *cannot* see because
they carry no package metadata. IREE and PyAV both ship as wheels installed
into /opt/venv with dist-info, so the syft half (.github/workflows/sbom.yml,
which scans `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`
directly from the registry) does catalogue them. For these two the gap is a
curation-policy inconsistency (deps.json already lists PyTorch, TVM, ONNX
Runtime, uv, Node — all metadata-bearing) rather than a total blind spot. The
genuinely uncovered surface is the human-facing licence inventory: docs/third-
party-licenses.md and the webserver-served pages, which have no scanner-fed
counterpart at all. Correction 2 — the copyleft framing does not apply to
these two instances. PyAV is BSD-3-Clause and IREE is Apache-2.0-with-LLVM-
exception; both are attribution-only. The GPL-configured FFmpeg that PyAV
links already has its own deps.json entry with a `source` block, so no source
offer is currently missing. The mechanism would equally hide a copyleft
component (the obligations check only walks deps.json), but the two known
instances are permissive, so the omission is an attribution gap, not a
discharged-obligation gap.

## F. Code cleanliness — the refactor queue (measured 2026-08-31)

Numbers, not opinions: function lengths from an AST-free line count, duplication
from `docs/scripts/verify_code_dupes.py`. Nothing here breaks a build; this is
the "I want clean code" queue. Ordered by value, not size.
