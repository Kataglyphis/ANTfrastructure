# Build secrets (BuildKit `--secret`)

How to give a build a credential — a private-repo token, a registry login, a
package-index password — **without** that credential landing in an image layer,
in the build cache, or in the repository.

The repo runs an enforcing secret scan (`secret-scan` in
`linux/scripts/preflight.sh`, via `linux/scripts/lint-secrets.sh`), so a
credential committed by accident fails the gate. This page is the sanctioned way
to avoid needing one in the first place.

## Why not the obvious approaches

| Approach | What goes wrong |
|---|---|
| `ARG TOKEN` + `--build-arg` | Recorded in image metadata; `docker history` shows it |
| `COPY .netrc /root/` | Becomes a layer. Deleting it in a later layer does not remove it |
| `ENV TOKEN=...` | Persists into every derived image and every running container |

A BuildKit secret mount is none of these: the file is exposed only for the
duration of one `RUN`, on a tmpfs, and is never committed to a layer.

## The pattern

**1. Put the credential in a file outside the build context.** For a git host,
a `.netrc` is the least invasive form — `git` picks it up with no other config:

```bash
cat > .gitlab.netrc <<'NETRC'
machine git.example.com
login <username>
password <PERSONAL_ACCESS_TOKEN_OR_DEPLOY_TOKEN>
NETRC
```

Make sure this file is covered by [`.gitignore`](../.gitignore) and
[`.dockerignore`](../.dockerignore) before you create it.

**2. Pass it to the build by id, not by value:**

```bash
docker build \
  --secret id=gitlab_netrc,src=./.gitlab.netrc \
  -t ghcr.io/kataglyphis/<image>:latest \
  --push .
```

**3. Mount it for exactly the step that needs it:**

```dockerfile
RUN --mount=type=secret,id=gitlab_netrc <<'EOF'
set -euo pipefail

# The secret is mounted read-only at /run/secrets/<id> by default.
cp /run/secrets/gitlab_netrc /root/.netrc
chmod 600 /root/.netrc
trap 'rm -f /root/.netrc' EXIT

git clone https://git.example.com/<org>/<repo>.git
uv pip install -v -e ./<repo>
EOF
```

## Details that matter

- **Default mount path is `/run/secrets/<id>`.** Override with
  `target=/some/path` if a tool insists on a fixed location.
- **The copy is what needs cleaning up, not the mount.** The mount disappears
  when the `RUN` ends. The `cp` to `/root/.netrc` does not — hence the `trap`.
  Without it the credential is committed to that layer, which is exactly the
  failure the secret mount exists to prevent.
- **Keep it to one `RUN`.** A secret mounted on step N is not visible on step
  N+1. Cloning and installing in the same heredoc is deliberate.
- **`set -euo pipefail` inside the heredoc.** Without it a failed `git clone`
  still exits 0 and the build continues with an empty directory — see the shell
  safety conventions in [`AGENTS.md`](../AGENTS.md).
- **Requires BuildKit.** Both `docker buildx build` and `nerdctl build` use it;
  a legacy `DOCKER_BUILDKIT=0` build rejects `--secret`.

## Windows: a secret from the environment (the sccache S3 key)

The Windows lane's one build secret is the key to sccache's shared S3 bucket
([`windows-build-resources.md` § Two cache levels](windows-build-resources.md#two-cache-levels)).
It never exists as a file, on either side of the build:

| Where | What holds the key |
|---|---|
| The build host | Two user environment variables, `KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID` and `KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY`. `Set-SccacheS3Level.ps1` asks for the secret without echo and stores it there. |
| The build call | `--secret id=sccache_s3_secret,env=KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY`: buildctl reads the variable and sends the value, never the command line. |
| The RUN | `--mount=type=secret,id=sccache_s3_secret,env=AWS_SECRET_ACCESS_KEY`: set for that RUN only, with nothing left in the layer (probed 2026-10-15). |
| The image | Nothing. The publish gate fails an image environment carrying `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` or `AWS_SESSION_TOKEN`. |
| The server | `/root/sccache-s3-key.txt` and `/etc/sccache-evict.env`, both mode 600. |
| The repositories | Placeholders only: `REPLACE_ME`, `GKEXAMPLE0000`, `GK0123456789abcdef01234567`. |

On Windows, prefer the `env=` form over a file target. A file target works too,
but it needs a forward-slash path (`target=C:/…`) and it leaves a 0-byte
placeholder in the layer.

A secret pasted into a chat, an issue or a log has left the machine: rotate it.
On the server that is `garage key create`, then `garage bucket allow`, then
`garage key delete` on the old key ([`linux/sccache-s3/README.md`](../linux/sccache-s3/README.md)).
The objects in the bucket stay valid. Then run `Set-SccacheS3Level.ps1` again on each host.

## Runtime secrets: Compose, not BuildKit

Everything above is **build**-time. A secret a *running* container needs is a
different mechanism — Compose mounts it at the same `/run/secrets/<id>` path,
but from a `secrets:` block rather than a `--secret` flag:

```yaml
services:
  myservice:
    image: example/image
    secrets:
      - account_token
    environment:
      - ACCOUNT_TOKEN=/run/secrets/account_token

secrets:
  account_token:
    file: account_token.txt
```

Note what the environment variable holds: the **path** to the secret, not the
secret. Services that expect the value inline need reading from that path
instead, and passing the value directly through `environment:` puts it in
`docker inspect` — which is the thing this avoids.

The backing file (`account_token.txt` here) sits next to the Compose file and
must be covered by [`.gitignore`](../.gitignore) before it is created.

## Private QAIRT endpoint handoff

Use `linux/scripts/qairt-key-handoff.py` when the Windows peer needs to send its existing
private WebDAV endpoint through coordination issue249. The helper exchanges the endpoint;
it does not transfer QAIRT or authenticate the sender. Use the established authenticated
issue account, and keep the separately confirmed SSH ED25519 host identity unchanged.

```bash
key_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ANTfrastructure/qairt/issue-249-001"
python3 linux/scripts/qairt-key-handoff.py keygen --directory "$key_dir"
python3 linux/scripts/qairt-key-handoff.py public --directory "$key_dir"
```

Publish only the returned PEM SubjectPublicKeyInfo and its lowercase SHA256 over DER SPKI.
This is a fresh RSA-3072 recipient key; its private directory is0700 and files are0600,
outside every checkout. Existing directories and output files are refused.

The peer encrypts only the UTF-8 endpoint, with RSA-OAEP, SHA256, MGF1-SHA256 and an empty
label. The payload is at most318bytes and contains no embedded credentials, query or fragment.
The reply names the public-key comment and fingerprint and carries the384-byte ciphertext as
Base64. Never put the endpoint, private key, credentials or SDK bytes in the issue.

```bash
python3 linux/scripts/qairt-key-handoff.py decrypt --directory "$key_dir" \
  --ciphertext /path/to/public-ciphertext.b64 --expected-fingerprint "$public_key_fingerprint"
```

Set `public_key_fingerprint` to the published `sha256_spki` value. Decryption validates the
key pairing and fingerprint and writes only private `endpoint.txt`;
stdout reports status and the public fingerprint. Wrong algorithms, tampering and failures
with stale output are rejected without child diagnostics. Verify the existing service and
private route before the separate transfer, then preserve the original archive size/hash and
cache gates. Keep the key until the handoff is acknowledged; retire it after confirmed transfer.
The regression suite proves file/cryptographic boundaries, not reachability or a completed SDK copy.

### Verified private SDK delivery

After the existing private route and permitted delivery have been confirmed, reuse
`linux/scripts/qairt-private-transfer.py` beside `qairt-key-handoff.py`. It reads the protected
endpoint file directly, checks the retained recipient key/fingerprint and accepts literal private
addresses only. It uses no environment proxy, follows no redirect and creates no service or grant.
Choose the original archive pin, byte count and exact preseed object agreed with the receiver:

```bash
python3 linux/scripts/qairt-private-transfer.py --directory "$key_dir" \
  --archive "$verified_archive" --fingerprint "$public_key_fingerprint" \
  --object-path "$preseed_object_path" --bytes "$archive_bytes" --sha256 "$archive_sha256" \
  --timeout 900 --receipt logs/test-results/qairt-private-transfer-001.json
```

Run the command as a named bounded user unit. The CLI adds a whole-operation deadline and local
private-directory lock, refuses an existing receipt and emits no endpoint or raw error text.
It hashes the original regular archive before any HTTP request and rechecks the sent stream and
source identity. Existing objects are fetched and fully hashed without PUT; mismatched objects
refuse. A missing object uses `If-None-Match: *`, and completion requires a full GET/hash check.
A412 race also requires matching full bytes. The no-replace condition relies on a compliant
server; a receipt describes the checked HTTP representation, not immutable storage thereafter.
Failures or partial uploads never authorize automatic overwrite or deletion.

The peer still fetches and hashes through its original downloader/cache gate. Neither this
transport receipt nor endpoint encryption authenticates a peer, installs the SDK, changes its pin
or proves a Windows build. Keep the archive off public issues and compiler S3. Local HTTP fixtures
cover bad bytes, preconditions, races, redirects, privacy, locking and a trickled-response deadline;
they do not establish the actual Windows service, TLS behavior or receiver cache acceptance.

## See also

- [Code quality tooling](code-quality-tooling.md) — the gate list, including the
  secret scan
- [`.gitleaks.toml`](../.gitleaks.toml) — the scan's allowlist: each entry pins
  one value and needs a written justification; needing a new one usually means
  a real secret got committed. `.gitleaksignore` is kept empty on purpose.

