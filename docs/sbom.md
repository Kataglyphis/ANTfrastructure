<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# SBOM — generating it, and what it is actually for

A Software Bill of Materials is only worth the work if something consumes it.
This page covers both halves of this project's SBOM, how to produce them, and —
the part usually left out — **what you can do with the result**.

Licence obligations are a different question and live in
[`third-party-licenses.md`](third-party-licenses.md). The SBOM tells you *what
is in the image*; that page tells you *what each licence requires of you*, and
its [Maintaining this list](third-party-licenses.md#maintaining-this-list)
section is the procedure for adding a component to the curated half.

## Why there are two halves

| Half | Produced by | Covers | Strength |
|---|---|---|---|
| **Scanner** | `syft` against the published image | apt/deb, PyPI, cargo, maven, npm, Go | breadth — thousands of packages |
| **Curated** | [`scripts/generate_sbom.py`](scripts/generate_sbom.py) from `deps.json` + `versions.env` | the source-built stack | correctness — right version, right licence, source pointer |

Neither is sufficient alone, and the reason is measurable rather than
theoretical. From a real scan of `:latest-cross` (`linux/amd64`, syft 1.51.0,
2026-08-25):

- **4,112 packages** catalogued (2,202 distinct names) — maven 1,340, deb 1,255,
  cargo 1,072, pypi 228, npm 149, go 13. No human maintains that by hand.
- **73 % of them carry no declared licence**, and **94 % no concluded licence**.
- For the components that actually carry a copyleft obligation, the scan reports
  the **distro copy at a different version**, or nothing at all:

  | Built and shipped here | What the scan reports |
  |---|---|
  | FFmpeg `n9.0`, `--enable-gpl --enable-version3` → **GPLv3** | `62.12.102`, `62.28.102`, `7:8.0.1-3ubuntu2`, licence `NOASSERTION` |
  | GStreamer `1.29.2` from source | `gstreamer1.0 1.28.2-1` — the Ubuntu package |
  | GCC `16.2.0` from source | `16.2.0`, plus Ubuntu's `15.2.0`, licence `NOASSERTION` |
  | OpenCV, TVM, Abseil, VVdeC | **not found at all** |

### The Windows image behaves differently again

Scanning `:winamd64` (syft 1.51.0, 2026-08-25) returns **26,253 packages** — six
times the Linux count, and far noisier:

| Ecosystem | Count | What it really is |
|---|---|---|
| no-purl | 14,014 | PE version resources read out of every `.dll`/`.exe` — "Microsoft® Windows Repair Disc", "JP Japanese Keyboard Layout for NEC PC-9800", "ApiSet Stub DLL". Operating-system files, not dependencies you chose |
| nuget | 10,201 | MSVC/Build Tools package graph |
| cargo | 1,554 | Rust crates |
| pypi | 449 | wheels |

**98.5 % carry no declared licence.** Treat the Windows scan as raw evidence
rather than an inventory: it needs filtering before it means anything, and the
package count is not a quality signal.

> **It also caught a real drift.** The scan reports ONNX Runtime **1.27.0**,
> TVM **0.25.0** and FFmpeg **8.0.git**, while `versions.env` pins **v1.29.0**,
> **v0.26.0** and **n9.0**. The published `:winamd64` image is behind the
> current pins — which means the curated SBOM and the licence pages, both
> generated from `versions.env`, describe *what the pins say* rather than *what
> was last published*. Re-publish the image, or read the curated documents as
> describing the next build rather than the current tag.

**So a source-offer question cannot be answered from the scanner SBOM.** That is
what the curated half exists for: it carries the exact upstream revision, the
build flags that determine the licence, and the corresponding-source pointer.

## Generating them

```bash
# Curated half — offline, no image needed, byte-reproducible
python3 docs/scripts/generate_sbom.py --write     # -> docs/deps/sbom-curated.spdx.json
python3 docs/scripts/generate_sbom.py --check     # gated in preflight as slug `sbom`

# Scanner half — reads straight from the registry, no daemon, no local build
syft "registry:ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  --platform linux/amd64 \
  -o spdx-json=out/sbom/scanned-linux-amd64.spdx.json \
  -o cyclonedx-json=out/sbom/scanned-linux-amd64.cdx.json

# What each half sees, and what only the curated one covers
python3 docs/scripts/compare_sbom.py out/sbom/scanned-linux-amd64.spdx.json
```

`:latest-cross` is a **manifest list** — a scan without `--platform` silently
picks one architecture. Scan each one you publish.

CI runs the scan weekly in [`sbom.yml`](../.github/workflows/sbom.yml) and
verifies the curated document has not drifted from `deps.json`.

## What you can actually do with it

### 1. Find vulnerabilities without rebuilding

The immediate payoff. `grype` consumes an SBOM directly, so you can re-check a
*published* image against today's CVE feed without pulling or rebuilding it:

```bash
grype sbom:out/sbom/scanned-linux-amd64.spdx.json
grype sbom:out/sbom/scanned-linux-amd64.spdx.json --fail-on high
```

Scanning the SBOM rather than the image is the difference between seconds and a
multi-gigabyte pull, which is what makes it viable to run on a schedule against
every published tag.

### 2. Answer a customer or procurement request

"Send us your SBOM" is now a file, not a project. Give them **both** documents:
the scanner half for breadth, the curated half because it is the one with
correct licences. SPDX and CycloneDX are both emitted — ask which they want
rather than guessing; tooling on their side usually accepts only one.

### 3. Diff two releases

```bash
python3 - <<'PY'
import json
def names(p): return {x["name"]: x.get("versionInfo","") for x in json.load(open(p))["packages"]}
a, b = names("sbom-old.spdx.json"), names("sbom-new.spdx.json")
print("added:  ", sorted(set(b) - set(a))[:20])
print("removed:", sorted(set(a) - set(b))[:20])
print("changed:", [k for k in a.keys() & b.keys() if a[k] != b[k]][:20])
PY
```

A dependency that appeared without anyone deciding to add it is exactly what
this catches — and on this chain, a new transitive crate or wheel arrives
without a commit that mentions it.

### 4. Gate on policy

Feed the SBOM to a policy engine and fail a release on rules you choose:
no new copyleft in a shipped layer, no package above a CVE severity, no
component without a licence. `grype --fail-on`, Anchore policy bundles and
OSS Review Toolkit all read these formats.

### 5. Track it over time

[Dependency-Track](https://dependencytrack.org/) ingests CycloneDX and keeps a
running inventory across releases, alerting when a *previously shipped* version
becomes vulnerable. That is the case a point-in-time scan cannot cover: the
image did not change, the world did.

### 6. Regulatory readiness

The EU Cyber Resilience Act obliges manufacturers of products with digital
elements to maintain an SBOM covering at least the top-level dependencies.
Having one generated and gated is materially easier than producing one later
under a deadline. This is context, not legal advice.

## What it does not tell you

- **Whether you may redistribute a component.** The proprietary entries
  (CUDA, Visual Studio Build Tools, Windows Server Core) carry vendor EULAs;
  an SBOM records their presence, not your right to ship them.
- **Whether a CVE is exploitable in your usage.** A hit is a prompt to look,
  not a verdict. VEX is the vocabulary for recording that judgement.
- **Complete licence coverage from the scan alone** — 73 % of scanned packages
  declare no licence at all. Treat the scanner half as an inventory and the
  curated half as the licence record.
- **Whether the scan and the curated half describe the SAME artifact.** The
  curated document is generated from `versions.env`, so it describes the pins.
  The scan describes a published tag, which may have been built earlier — as of
  2026-08-25 the Windows image was behind on three components. Compare the two
  before quoting either as current.
- **Anything about components with no metadata.** A `.so` copied into `/opt`
  during a source build is invisible to any scanner. That gap is precisely what
  the curated half fills, and why adding a copyleft component without a source
  pointer fails the gate.
