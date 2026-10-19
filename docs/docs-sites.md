# Docs sites: build, check, publish

Every family repository publishes a documentation site to its own subdomain of the
FTP host (Apache, one docroot per site). They all go through one reusable workflow,
`.github/workflows/build-docs.yml`: build the site in the family image, add the hub's
`.htaccess`, check every internal link, publish. The upload itself is
[`deploy-over-ftp`](ftp-deploys.md).

## The reusable workflow

```yaml
# .github/workflows/docs.yml in the repository
name: Docs · build + publish
permissions:
  contents: read
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]
  workflow_dispatch:
jobs:
  docs:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/build-docs.yml@develop
    with:
      builder: rustdoc
    secrets:
      FTP_SERVER: ${{ secrets.SERVER }}
      FTP_USERNAME: ${{ secrets.USERNAME }}
      FTP_PASSWORD: ${{ secrets.PW }}
```

Two jobs (2026-10-19):

- **`site`** builds the site in the family image (`command` or `builder`), or takes the
  artifact an earlier job of the run uploaded (`artifact`). `docs-site.sh stage` then adds
  the `.htaccess` and 404 page and runs the [link gate](#the-built-site-link-gate); the
  checked tree is uploaded as `docs-site-<site-name>`, hidden files included. A newer
  commit on the same ref cancels this job.
- **`publish`** downloads that tree and runs `deploy-over-ftp`. It runs only on a **push to
  `develop` or `main`**, or a dispatch there with `publish-on-dispatch: true`; never on a
  pull request. Its concurrency group is `docs-publish-<site-name>`, one per repository
  and site, with `cancel-in-progress: false`: a newer run waits, an upload is never cut
  off. It holds the only FTP secrets; the build never sees them.

There is no `continue-on-error` anywhere: a red link gate or a failed upload is a red job,
and the site keeps its last good deploy.

**Call it from a `docs.yml` of its own.** A caller workflow with a cancelling
`concurrency:` (most `linux-x64.yml`s) cancels a publish half-way on the next push, and a
docs site published from inside a build or test job goes stale when a test is red or a
commit changes only docs. The hub's own caller is `.github/workflows/docs.yml`.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `command` | `''` | Builds the site: `bash -lc` in the family image at the repository root |
| `builder` | `''` | A hub driver instead: `rustdoc` (`cargo_build_doc.sh`, site `target/doc`), `python` (`ci_build_docs.sh`, site `docs/build/html`) or `dartdoc` (`doc/api` cleared, then `dartdoc_build_main` with DocumANTation's theme after `flutter pub get`, `images/` copied when the repository has one, site `doc/api`) |
| `guides` | `''` | `builder: dartdoc` only: the Markdown guides rendered beside the API pages, one `<source>\|<slug>\|<nav title>` per line (a YAML `\|` block), sources relative to the repository root. `docs-site.sh plan` refuses it with any other source, a source outside the checkout, and a slug that is not `[A-Za-z0-9_-]` |
| `artifact` | `''` | A site an earlier job of the run uploaded; nothing is built |
| `site-dir` | `''` | The built site, relative to the repository root; required with `command`, empty with `artifact` |
| `site-name` | `docs` | Names the uploaded site and the publish group; a second site of the same repository needs its own |
| `link-allow` | `''` | The link gate's allow file, relative to the repository root |
| `htaccess` | `true` | Add the hub's `.htaccess` and 404 page; `false` for a site that ships its own |
| `publish` | `true` | `false` builds and checks only, and needs no secrets |
| `publish-on-dispatch` | `false` | Also publish a `workflow_dispatch` run on `develop` or `main` |
| `server-dir` | `''` | Remote directory; empty is the FTP login directory, every family site's docroot |
| `submodules` | `recursive` | `actions/checkout` submodules. Pass a value as an expression (`${{ 'true' }}`): actionlint reads a bare `'true'` as a bool |
| `container-args` | `''` | Extra `docker run` arguments for the build, verbatim: never untrusted text |
| `hub-path` | `''` | A hub checkout to take the drivers, the stager and the gate from; empty checks the hub out at `develop` into `antfrastructure-tools`, so they match the workflow. The hub passes `.` |
| `runner` | `ubuntu-26.04` | Runner label |

Exactly one of `command`, `builder` and `artifact`; `docs-site.sh plan` refuses anything
else, and a `site-dir` or `hub-path` that is not a plain relative path.

### Secrets

The workflow takes **`FTP_SERVER`, `FTP_USERNAME` and `FTP_PASSWORD`**, the names
`python-ci-linux.yml` already used, and no other spelling. A caller maps its repository
secrets onto them in its `secrets:` block: most repositories store `SERVER`, `USERNAME`
and `PW`, WebDavClient `PASSWORD`, jotrockenmitlocken's docs site `DOC_WEBSITE_SERVER`,
`DOC_WEBSITE_USER` and `DOC_WEBSITE_PW`. No repository secret has to be renamed. A publish
without them fails in its first step and names the missing ones. The
`SERVER`/`USERNAME`/`PW` secret inputs of the consumers' own `reusable-*.yml` go away
with their deploy steps (below).

### Moving a repository onto it

What each repository changes, read 2026-10-19 from its `develop`. Each one seeds
`link-allow` from its first run's findings (`verify_site_links.py <site> --print-keys`) or
fixes them.

| Repository | Today | Change |
|---|---|---|
| ANTfrastructure | `linux-x64.yml` called `build-docs.yml` under a cancelling group | done: `docs.yml`, `command: bash linux/scripts/build-docs.sh`, `site-dir: docs/_build/html`, `hub-path: .` |
| OrchestrANT, WebDavClient | `python-ci-linux.yml` published from its x64 build job, on any push | nothing: its new `docs` job calls this workflow with `artifact: python-docs-site` and publishes on `develop` and `main` only; optional `docs-link-allow` |
| OxidANT | `reusable-linux.yml` built rustdoc and published with `continue-on-error: true` | a `docs.yml` with `builder: rustdoc`; the `docs` input, both docs steps and the three secrets leave `reusable-linux.yml` and `linux-x64.yml`. Its 11-crate site has 20 `missing <module>/dispatcher` keys from `tracing`'s blanket-impl docs, so it needs an allow file |
| OmniAccelerANT | `reusable-linux.yml` published `doc/api` after the whole native lane | a `docs.yml` with `command: bash scripts/linux/generate-docs.sh`, `site-dir: doc/api`; `run-docs` off, the deploy step and its three secrets go |
| AccelerANTgine | `reusable-linux.yml` published from the clang x64 build, whose docs carry its coverage, on every event but a dispatch, pull requests included | artifact mode: the deploy step becomes an `upload-artifact` of `docs/build/html/` named `accelerantgine-docs-site` (`include-hidden-files: true`, `if-no-files-found: error`), and `linux-x64.yml` gets a `docs` job that `needs: build-ubuntu26_04_clang-x64` with `artifact: accelerantgine-docs-site` |
| BeschleunigerBallett | `reusable-linux.yml` published on every event but a dispatch, pull requests included, with `continue-on-error: true` | artifact mode as AccelerANTgine: upload `docs/build/html/` as `bb-docs-site` after the wasm budget step; `linux-x64.yml` gets a `docs` job, `needs: build-x64`, `if: ${{ !cancelled() }}` |
| ANThology | `docs.yml` ran `dart doc` after the Dart checks, in the same job | done (c3615ca): a `docs` job with `command: bash scripts/build-docs.sh`, `site-dir: doc/api`, because the builder took no guide list then. It can move to `builder: dartdoc` with `guides: docs/getting-started.md\|getting-started\|Getting started`: run twice in `:latest` over its checkout, 1071 documents, 0 findings, 57 s, the rebuild 29 s |
| jotrockenmitlocken | `web.yml` published `doc/api` with no `if:`, after the whole web build | a `docs` job with `command: bash scripts/ci-container-steps.sh dart-doc`, `site-dir: doc/api`, `container-args: --platform linux/amd64`, secrets from `DOC_WEBSITE_*`. Its three web-app deploys stay on `deploy-over-ftp`: an app ships its own `.htaccess` |

DocumANTation publishes to GitHub Pages and is not an FTP site.

## The built-site link gate

`linux/scripts/verify_site_links.py <site dir> [--allow FILE] [--print-keys]` reads a
built HTML tree offline and fails when an internal link or anchor resolves to nothing.
Stdlib only; it runs in the family image or on any Python 3.

What it checks, in every HTML document of the tree:

- **every `href`, `src` and meta-refresh target** inside the site exists. A link to a
  directory needs that directory's `index.html`; an absolute path (`/a.html`) is served
  from the site root, because every family site is served at its domain root; a
  relative link that climbs above the root fails even when the build host has a file
  there. External links, `mailto:` and the like are not checked;
- **every anchor** names an `id` or `<a name>` on its target page, as written or
  decoded (rustdoc writes `impl-From%3CT%3E-for-T`). `#top` always resolves, and a
  rustdoc source range (`lib.rs.html#22-31`) needs both ends;
- **the root has an `index.html`.**

A `<base href>` moves the links of its page, as in a browser. A file without
`<!DOCTYPE html>` or `<html>` is not a document: dartdoc's `*-sidebar.html`
fragments are injected into other pages, so their links are relative to those.

**Known exceptions** go into an allow file, one key per line, `#` comments allowed.
The keys are what the gate prints: `missing<TAB><path>` and
`anchor<TAB><page>#<fragment>`, paths relative to the site root. It follows the
two-way rule of [the allowlist contract](code-quality-tooling.md#the-allowlist-contract):
a finding not frozen fails, and a frozen key that resolves now is STALE and fails.
`--print-keys` prints the current findings in that shape, to seed the file. A
missing allow file is a usage error (exit 2), not an empty freeze.

Measured 2026-10-19 in `:latest`:

| Site | Documents | Findings |
|---|---|---|
| this hub (Sphinx, DocumANTation 4866eae) | 94 | 3 dead anchors: two Markdown links to a directory in `adopting-in-a-new-project.md` and one in `upstream-windows-patches.md`, which the theme renders as `#../linux/scripts/01-core/`. Fixed the same day: they point at the GitHub tree |
| OxidANT rustdoc, all 11 crates (`8af8f67`) | 517 | 20 `missing <module>/dispatcher`, one per module of `kataglyphis_webgpu_renderer` |
| ANThology through `builder: dartdoc` | 1070 | 0, once the builder copied `images/`: the README's `images/logo.png` was the one dead link |

Suite `linux/scripts/tests/test-site-links.sh`; the `site-links.*` mutations prove it.

## The site's .htaccess

`linux/webserver/templates/docs-site.htaccess` goes into every docs site's root, with
`docs-site-404.html` as `404.html` when the build wrote none:

| Directive | Why |
|---|---|
| `RewriteCond %{HTTPS} !=on` + `RewriteCond %{HTTP:X-Forwarded-Proto} !=https` + `RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]` | plain http answered 200 on every family site; the second condition stops a loop behind a proxy that ends TLS |
| `Header always set Strict-Transport-Security "max-age=31536000"` | HSTS for a year, this subdomain only |
| `Header always set X-Content-Type-Options "nosniff"` | no content sniffing |
| `RedirectMatch 404 (^\|/)\.ftp-deploy-sync-state\.json$` | the FTP library's state file lists every published file with its hash, and it was served |
| `ErrorDocument 404 /404.html` | a dead link shows a page with a way back, not Apache's default |

**Every directive is in Apache's FileInfo override class**, and the suite fails on any
other. That class is what the host is proven to allow: `jonasheinle.de`, on the same
address as every docs site, serves exactly the headers of jotrockenmitlocken's deployed
`web/.htaccess` (`Header`, `AddType`). A directive the host's `AllowOverride` does not
grant (`Options`, `Require`, `Order`) would make every page a 500, so the state file is
denied by `RedirectMatch` rather than `Require all denied`. Each block sits in
`<IfModule>`: a missing module drops its rules instead of failing the site.

The server, read 2026-10-19 with `curl -sI`: `containerization.jonasheinle.de` and the
other eight FTP sites answer `Server: Apache` from `85.13.169.97`; `http://` answers 200
with no redirect; `/.ftp-deploy-sync-state.json` answers 200; an unknown page gets
Apache's default 404; `/.htaccess` answers 403, so the server config denies `.ht*`
files itself.

The family image carries no `httpd`, so the directives are checked by
`linux/scripts/tests/test-docs-site-htaccess.sh` (each directive, the state-file regex
against sample paths, the 404 page through the link gate) and by `curl -sI` after the
first publish, not by a server in a container. The `docs-site.*` mutations prove the
suite.
