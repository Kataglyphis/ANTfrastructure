<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# GPU package receipts

`shared/python/gpu_artifact_receipt.py` binds a flat set of named package files to
a caller-supplied CI identity and a named passed check. It uses only the Python
standard library and runs on Windows and Linux. It is a building block; it is not
yet connected to any release workflow.

Both `create` and `verify` require the same arguments: `--directory`, `--receipt`,
one `--file` per expected package, `--repository`, `--revision` (a full 40-digit
lowercase commit SHA), `--run-id`, `--run-attempt`, `--artifact-id`,
`--artifact-digest` (the upload action's bare SHA-256 archive digest), `--platform`,
`--arch`, `--vendor` and `--check` (a stable check name). IDs and attempts are
positive decimal integers. The supported tuples are Linux x64 NVIDIA/AMD, Linux
arm64 NVIDIA, and Windows x64 NVIDIA/AMD. The receipt must be outside the package
directory; `create` refuses to overwrite an existing file.
An optional `sha256:` prefix is accepted and normalized to the same bare digest.

The directory must contain exactly the named regular files: extras, subdirectories,
links, duplicate names and path components fail. The receipt records each file's
SHA-256 separately from the Actions archive digest. `verify` compares the caller's
expected identity and filenames against the receipt and rehashes the packages.
Malformed or duplicate JSON fields and a status other than `passed` fail.

For a trusted Linux x64 NVIDIA job, for example, assemble the arguments from the
workflow's own context and the upload action's outputs, then use them after the
checks described below:

```bash
receipt_args=(--directory "$PACKAGES" --receipt "$RECEIPT"
  --file app.deb --file app.AppImage --repository "$GITHUB_REPOSITORY"
  --revision "$GITHUB_SHA" --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT"
  --artifact-id "$ARTIFACT_ID" --artifact-digest "$ARTIFACT_DIGEST"
  --platform linux --arch x64 --vendor nvidia --check gpu-model-inference)
python3 shared/python/gpu_artifact_receipt.py create "${receipt_args[@]}"
python3 shared/python/gpu_artifact_receipt.py verify "${receipt_args[@]}"
```

**A receipt does not prove a GPU check happened or authenticate its author.** A
trusted workflow must download an immutable artifact ID with digest verification,
hash the packages before the hardware test, run the real named check against those
same bytes, and confirm their hashes did not change before creating a passed receipt.
This tool compares the supplied artifact ID and archive digest as identity strings;
it does not fetch GitHub metadata or independently verify the downloaded archive.
The workflow must obtain those values from trusted upload metadata and validate the
archive using a digest-verifying download action before invoking the tool.
Promotion must independently obtain the expected repository, commit, run, attempt,
artifact ID and digest from trusted workflow context, download that same ID, verify
the passed receipt and hashes, and enforce the required check for every tuple.
Do not read the expected values solely from the receipt being checked. Checks on
an untrusted runner cannot be made trustworthy by this file. Coordinate access to
the directory so other processes cannot replace files while they are being hashed.

An overwritten Actions artifact is a new artifact: bind to its ID, not only its
name. On a rerun, require matching run attempt and recreate all dependent receipts;
do not promote a stale receipt or a different matrix entry. GPU releases also need
explicit expected asset names and their existing clean-host and license checks.
