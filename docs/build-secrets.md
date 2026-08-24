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

## See also

- [Code quality tooling](code-quality-tooling.md) — the gate list, including the
  secret scan
- [`.gitleaksignore`](../.gitleaksignore) — every suppression needs a written
  justification; needing a new one usually means a real secret got committed
