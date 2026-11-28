# Docs sites: build, check, publish

Every family repository publishes its documentation site to its own subdomain of the
FTP host (Apache, one docroot per site) through one reusable workflow,
`.github/workflows/build-docs.yml`: build the site in the family image, add the hub's
`.htaccess`, check every internal link, publish. The upload is
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

- **`site`** builds the site in the family image (`command` or `builder`) and clicks its
  [sidebar toggles](#the-sidebar-toggle-check), or takes the
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

Image-backed site builds use the full runner disk cleanup before pulling the family image.
The pull is serialized after cleanup so its layers do not consume the space being reclaimed;
the caller's selected submodule checkout, including a pinned theme, is unchanged.

**Call it from a `docs.yml` of its own.** A caller workflow with a cancelling
`concurrency:` (most `linux-x64.yml`s) cancels a publish half-way on the next push, and a
docs site published from inside a build or test job goes stale when a test is red or a
commit changes only docs. The hub's own caller is `.github/workflows/docs.yml`.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `command` | `''` | Builds the site: `bash -lc` in the family image at the repository root |
| `builder` | `''` | A hub driver instead: `rustdoc` (`cargo_build_doc.sh`, site `target/doc`), `python` (`ci_build_docs.sh`, site `docs/build/html`) or `dartdoc` (`doc/api` cleared, then `dartdoc_build_main` with DocumANTation's theme after `flutter pub get`, `images/` copied when the repository has one, site `doc/api`) |
| `guides` | `''` | `builder: dartdoc` or `rustdoc`: the Markdown guides rendered beside the API pages, one `<source>\|<slug>\|<nav title>` per line (a YAML `\|` block), sources relative to the repository root. dartdoc writes `guide-<slug>.html` at the site root; rustdoc writes it beside the root package's `<crate>/index.html`, whose page it reuses, and lists every guide atop each page's sidebar. `docs-site.sh plan` refuses it with any other source, a source outside the checkout, and a slug that is not `[A-Za-z0-9_-]` |
| `artifact` | `''` | A site an earlier job of the run uploaded; nothing is built |
| `site-dir` | `''` | The built site, relative to the repository root; required with `command`, empty with `artifact` |
| `site-name` | `docs` | Names the uploaded site and the publish group; a second site of the same repository needs its own |
| `link-allow` | `''` | The link gate's allow file, relative to the repository root |
| `htaccess` | `true` | Add the hub's `.htaccess` and 404 page; `false` for a site that ships its own |
| `isolated-apps` | `''` | Web apps below the site's root, space-separated paths relative to it. Each gets [the isolated-app `.htaccess`](#an-isolated-apps-htaccess); `docs-site.sh stage` refuses a path outside the site, one without an `index.html`, and an app that ships its own `.htaccess` |
| `live-url` | `''` | The published site's `https://` address. With `isolated-apps`, a `live-check` job after the publish runs `check-live-site.js --isolated` on each app at `<live-url>/<app>/`, against the files it published. A red job means the live app is broken now |
| `publish` | `true` | `false` builds and checks only, and needs no secrets |
| `publish-on-dispatch` | `false` | Also publish a `workflow_dispatch` run on `develop` or `main` |
| `publish-timeout-minutes` | `30` | The publish job's limit. An upload it cuts off saves no sync state, so a file too large to finish in time is retried from scratch on every run: BeschleunigerBallett's 61 MB demo scene at about 74 kB/s never landed under 30 |
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
| OxidANT | `reusable-linux.yml` built rustdoc and published with `continue-on-error: true` | a `docs.yml` with `builder: rustdoc`; the `docs` input, both docs steps and the three secrets leave `reusable-linux.yml` and `linux-x64.yml`. Its 11-crate site has 20 `missing <module>/dispatcher` keys from `tracing`'s blanket-impl docs, so it needs an allow file. Since 2026-10-21 its eight `docs/` pages ride along as `guides` |
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

`SITE_LINK_JOBS` (default one per CPU) is how many processes parse the pages; `1` parses in the
gate's own process. The check then reads them in one fixed order, so the findings do not change.

What it checks, in every HTML document of the tree:

- **every `href`, `src` and meta-refresh target** inside the site exists. A link to a
  directory needs that directory's `index.html`; an absolute path (`/a.html`) is served
  from the site root, because every family site is served at its domain root; a
  relative link that climbs above the root fails even when the build host has a file
  there. External links, `mailto:` and the like are not checked;
- **every anchor** names an `id` or `<a name>` on its target page, as written or
  decoded (rustdoc writes `impl-From%3CT%3E-for-T`). `#top` always resolves, and a
  rustdoc source range (`lib.rs.html#22-31`) needs both ends;
- **the root has an `index.html`;**
- **no link is a Rust path** (`super::Subscriber`, `crate::dispatcher#…`). An intra-doc link
  rustdoc could not resolve keeps its text as the `href`. `urljoin` would read `super::` as a URL
  scheme and skip it as external. So the gate reports it as `unresolved`, one key per path. A
  scheme with one colon (`tel:`, `urn:`) is still a URL.

A `<base href>` moves the links of its page, as in a browser. A root-absolute one (`/app/`, as
Flutter's `--base-href` writes it) names the site's root, as an absolute link does. A file without
`<!DOCTYPE html>` or `<html>` is not a document: dartdoc's `*-sidebar.html`
fragments are injected into other pages, so their links are relative to those.

**Known exceptions** go into an allow file, one key per line, `#` comments allowed.
The keys are what the gate prints: `missing<TAB><path>`,
`anchor<TAB><page>#<fragment>` and `unresolved<TAB><link>`, paths relative to the site root. It follows the
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

## Links into dependencies

`cargo_build_doc.sh` documents with the pinned nightly: `cargo +${RUST_NIGHTLY_TOOLCHAIN} doc
-Zrustdoc-map`. It maps crates.io dependencies to docs.rs. A stable `cargo doc --no-deps` writes
no page for a dependency. Rustdoc then cannot resolve a link into one, and keeps its text as the
`href`. That text arrives through the blanket impls rustdoc copies onto every type page. tracing's
`WithSubscriber` and `Instrument` link `dispatcher#…`, `super::Subscriber` and `crate::Span`.
burn's `Module` links `ModuleMapper`. With the map, each goes to the dependency's page on docs.rs.

- The pin is `RUST_NIGHTLY_TOOLCHAIN` in `versions.env`. The image already carries it for the web
  lane, and a non-empty environment value wins. A host without it fails with the
  `rustup toolchain install` line to run.
- The gate does not check docs.rs links: they are external.
- `--extern-html-root-url` does the same per crate. Stable rustdoc refuses it without
  `-Z unstable-options`.
- Documenting a dependency beside the workspace (`-p tracing`) does not help. The workspace's own
  pages still carry the raw text. Only `cargo doc` without `--no-deps` resolves it locally. For
  OxidANT that documents every crate it depends on.

Measured in WSL against OxidANT's develop, on 18 of its 20 crates. The two that need GTK were left
out. Stable `--no-deps` gives 69 findings: 63 `missing` and 6 `unresolved`. The nightly with the
map gives none of them. The builds took 45 s and 48 s, with no rustdoc warning either way. Suite
`linux/scripts/tests/test-cargo-build-doc.sh`; the `rust.cargo-doc-*` mutations prove it.

## The sidebar toggle check

`linux/scripts/check-docs-sidebars.js <site dir | https URL> [page ...]` serves a built Sphinx
book-theme, dartdoc or rustdoc site on `127.0.0.1` (or opens a published one), and in the image's
headless Chrome clicks every sidebar toggle a reader can see, at the widths where the
layout changes: 1400, 1100, 850 and 400 px for Sphinx, 1400, 800 and 400 px for dartdoc,
1400, 700 and 400 px for rustdoc.
A toggle fails when it is off-screen, covered, does nothing, or opens a sidebar that does
not close again (second click, the overlay, or Escape for a dialog); a hidden sidebar with
no toggle fails too. Exit 1 on a failure, 2 on a usage error or no Chrome; any other site
has nothing to toggle and passes.

It opens `index.html`, each `page` named (a path under the site root), and in a built Sphinx
site every page with an Exhale tree view (`class="collapsibleList"`); a published site has no
file list, so name its API page (`api/library_root.html`). A built rustdoc site's `index.html`
is a redirect at best, so there it opens each crate page with guides beside it and those guides,
else the first crate of `crates.js`. On each page and width:

- **any uncaught exception or rejection fails**, with its message and source line;
- **an Exhale tree view** gets its first foldable item clicked on its own text, never its
  link: an item that never folds (its script did not run), stays put, or does not unfold
  again fails.

For this hub, `docs.yml` type-checks `docs/conf.py` against the checked-out
DocumANTation theme before the reusable site job starts; a missing theme or type
finding prevents publication. `linux/scripts/lint-python-types.sh --docs-conf`
writes its ignored report under `logs/code-quality/`, while the Sphinx build
checks runtime rendering. The sidebar check runs where each site is built, in
the image: `docs-site.sh build <site>` builds and then
checks in one container command in `build-docs.yml` (the action's `script` is `docker
run`'s argv, so a shell `&&` would run on the runner), and for the artifact sites after `make html` in
`lib/docs-build.sh` (BeschleunigerBallett, AccelerANTgine) and
`02-toolchain/python/ci_build_docs.sh` (OrchestrANT, WebDavClient), with `--if-chrome`,
which skips only where the image sets no `CHROME_EXECUTABLE` (riscv64).

`CHECK_DOCS_SIDEBARS_JOBS` (default 4, at most the CPU count) is how many Chromes check pages
and widths at once; the report is the same, in page order. `1` checks them in turn (CON126).

Normal shared Chrome cleanup waits up to five seconds for child exit after sending
`SIGKILL`, then removes its profile with bounded filesystem retries. A still-running
profile writer previously caused `ENOTEMPTY` after a successful page check. Sidebar,
live-site and WebGPU callers await cleanup; exhausted retries, permission failures
or a child that does not exit remain fatal. All browsers finish cleanup before a
peer's failure is reported. The immediate process-exit handler only sends the kill.

`test-chrome-close.sh` uses real Node child processes and injected cleanup failures
to prove exit-before-removal, bounded retry policy, timeout, fatal errors and peer
cleanup. The browser/CDP behavior remains covered by the fixture sites below.
Real Chrome launches terminate their detached process group before reaping the main
child; standalone child fixtures keep direct termination as their default. Signal
handlers retain best-effort emergency cleanup. DevTools calls fail after 30 s.
A slower page's caller passes `send(method, params, timeoutMs)`.
If endpoint/page discovery, the WebSocket or initial DevTools calls fail before return, the launcher
cleans its group, profile and signal hooks itself. Cleanup failures retain the startup
error as well and remain fatal; fake-CDP cases cover this otherwise unowned launch path.

Why (CON121, 2026-10-20): every Sphinx site had dead or unreachable toggles and no gate
saw it.

- pydata-sphinx-theme 0.20, which sphinx-book-theme 1.4.0 pins, defaults
  `navbar_persistent` to the search field and renders its own header, with a hidden
  `.primary-toggle` and `.secondary-toggle`, before the book theme's article header. Both
  themes' JS bind `document.querySelector('.primary-toggle')`, the hidden one, so the
  visible toggles did nothing at any width on the five sites built from PyPI. DocumANTation's
  `setup_theme()` sets `navbar_persistent: []`.
- The theme's `custom.css` made `.bd-sidebar-primary` `position: sticky` at every width.
  Below the drawer breakpoint the sidebar is `position: fixed` with a negative margin;
  sticky kept it in the flow and moved the article's toggle to x=-242 at 850 px.

Why the exceptions and tree views (CON127, 2026-10-20): Exhale 0.3.7's
`apply-collapsible-lists.js` is `$(document).ready(...)`, and Sphinx 6 stopped shipping
jQuery, so every page of AccelerANTgine's and BeschleunigerBallett's sites threw
`ReferenceError: $ is not defined` and their API trees never folded, while every toggle
passed. DocumANTation's theme copies a jQuery-free applier over Exhale's when a site
builds one; Exhale's own `CollapsibleLists.js` needs no jQuery.

Suite `linux/scripts/tests/test-docs-sidebars.sh` (fixture sites, one per failure); the
`docs-site.sidebars-*` and `docs-site.*-clicks-the-toggles` mutations prove it.

## Proving a WebGPU page

In the image's headless Chrome 155 a WebGPU canvas screenshots white even when the page renders
it (CON128). Read the frame back instead:

```bash
node linux/scripts/webgpu-canvas-readback.js <URL | page.html> [--min-colours N] [--wait-ms N] [--screenshot FILE]
```

- Chrome runs WebGPU on SwiftShader (`--enable-unsafe-webgpu --enable-features=Vulkan
  --use-angle=swiftshader --use-webgpu-adapter=swiftshader`): the image has no GPU. A consumer
  driving its own page takes them from `require('webgpu-canvas-readback.js').WEBGPU_FLAGS`
  (frozen) for `check-docs-sidebars.js`'s `launch(chrome, WEBGPU_FLAGS)`, with `install` for
  the read-back. A traced frame can hold the page past 30 s.
- An init script (`Page.addScriptToEvaluateOnNewDocument`) adds `COPY_SRC` to the canvas's
  `configure()` usage and keeps the texture `getCurrentTexture()` hands out. After `--wait-ms`
  (3000) it copies the next frame out after that frame's last `submit()`
  (`copyTextureToBuffer`, rows padded to 256 bytes, then `mapAsync`).
- It prints size, format and distinct colours and paints the frame into a 2D canvas over the
  WebGPU one, so `--screenshot` shows it. Exit 1 on fewer than `--min-colours` (2: a cleared
  canvas has one), no frame in 10 s, or a format other than 8-bit RGBA/BGRA; 2 on a usage
  error or no Chrome.

BeschleunigerBallett's published demo (`/webgpu-demo/index.html`), 2026-10-20: 3575 colours for
the proof of run 39440853860, 3124 from this tool at `--wait-ms 8000`, both `1280x743 rgba8unorm`;
its plain screenshot was white.

Suite `linux/scripts/tests/test-webgpu-canvas-readback.sh` (the read-back against fakes of the
WebGPU API, the exported flags, a page with no frame in Chrome); the `docs-site.webgpu-readback-*` mutations prove it.

## The site's .htaccess

`linux/webserver/templates/docs-site.htaccess` goes into every docs site's root, with
`docs-site-404.html` as `404.html` when the build wrote none:

| Directive | Why |
|---|---|
| `RewriteCond %{HTTPS} !=on` + `RewriteCond %{HTTP:X-Forwarded-Proto} !=https` + `RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]` | plain http answered 200 on every family site; the second condition stops a loop behind a proxy that ends TLS |
| `Header always set Strict-Transport-Security "max-age=31536000"` | HSTS for a year, this subdomain only |
| `Header always set X-Content-Type-Options "nosniff"` | no content sniffing |
| `RedirectMatch 404 (^\|/)\.ftp-deploy-sync-state\.json$` | the FTP library's state file lists every published file with its hash, and it was served |
| `AddType application/wasm .wasm`, `AddType model/gltf-binary .glb`, `AddType model/gltf+json .gltf` | `WebAssembly.instantiateStreaming` refuses a wasm under any other type, and none of the three may hang on the host's `mime.types` |
| `AddOutputFilterByType DEFLATE application/wasm model/gltf-binary model/gltf+json` | the host gzips text itself but serves these whole: BeschleunigerBallett's demo is a 7 MB wasm and a 61 MB `.glb` that gzips to 30 MB. Inside `mod_filter` (owns the directive) and `mod_deflate` (owns the filter) |
| `ErrorDocument 404 /404.html` | a dead link shows a page with a way back, not Apache's default |

**Every directive is in Apache's FileInfo override class**, and the suite fails on any
other. That class is what the host is proven to allow: `jonasheinle.de`, on the same
address as every docs site, serves exactly the headers of jotrockenmitlocken's deployed
`web/.htaccess` (`Header`, `AddType`, and `AddOutputFilterByType DEFLATE`, which gzips its
`.wasm`). A directive the host's `AllowOverride` does not grant (`Options`, `Require`,
`Order`) would make every page a 500, so the state file is denied by `RedirectMatch`
rather than `Require all denied`. Each block sits in `<IfModule>`: a missing module drops
its rules instead of failing the site.

The server, read 2026-10-19 with `curl -sI`: `containerization.jonasheinle.de` and the
other eight FTP sites answer `Server: Apache` from `85.13.169.97`; `http://` answers 200
with no redirect; `/.ftp-deploy-sync-state.json` answers 200; an unknown page gets
Apache's default 404; `/.htaccess` answers 403, so the server config denies `.ht*`
files itself. Read 2026-11-15: HTML, CSS and JavaScript come back
`Content-Encoding: gzip` without any `.htaccess` rule, and
`beschleunigerballette.jonasheinle.de` sent its demo's `.wasm` as `application/wasm` but
uncompressed, so the template compresses the binary types only.

The family image carries no `httpd`, so the directives are checked by
`linux/scripts/tests/test-docs-site-htaccess.sh` (each directive, the `<IfModule>` guards
around the types and the filter, the state-file regex against sample paths, the 404 page
through the link gate) and by `curl -sI` after the first publish, not by a server in a
container. The `docs-site.*` mutations prove the suite.

## An isolated app's .htaccess

A web app that needs `crossOriginIsolated` gets `linux/webserver/templates/flutter-web-isolated.htaccess`
as the `.htaccess` of its own directory. On a docs site, name the app's directory in `isolated-apps`, and
the stager copies the template there before the link gate runs. Wasm threads, `SharedArrayBuffer` and ORT Web's threaded builds
need isolation. OmniAccelerANT's `/app/` takes this template below its docs site's root. The root keeps
`docs-site.htaccess`, and jotrockenmitlocken keeps `flutter-web.htaccess`.

| Directive | Why |
|---|---|
| `Header always set Cross-Origin-Opener-Policy "same-origin"` | one of the two headers that isolate the page |
| `Header always set Cross-Origin-Embedder-Policy "require-corp"` | the other one; Safari has no `credentialless` |
| `Header always set Permissions-Policy "camera=(self)"` | `getUserMedia` for this origin, and for no embedded frame |
| `AddType application/wasm .wasm`, `AddType text/javascript .mjs` | the browser refuses a wasm or a module script served under another type |
| `Header set Cache-Control "no-cache"` | `main.dart.wasm` and `flutter_bootstrap.js` keep their names across builds, so the browser must revalidate them |
| `SetEnvIf Request_URI ... VERSIONED_PATH` and `Header set Cache-Control "public, max-age=31536000, immutable" env=VERSIONED_PATH` | only `ort/<version>-<build hash>/` and `models/<sha256>/` never change under their name. The guarded line comes after the plain one and overwrites it |
| The HTTPS redirect, HSTS, `nosniff`, the sync-state `RedirectMatch` and the wasm `DEFLATE` | the root's rules again, so the file also works at a docroot |

The FileInfo rule of the root's file holds here too, with the same `<IfModule>` guards. `SetEnvIf` is in
FileInfo. `<If>` is not: it needs `AllowOverride All`, so the versioned paths are matched by `SetEnvIf`.

Apache merges `Header` and `AddType` from the root's file into a subdirectory's. Rewrite rules do not
merge: a subdirectory file with its own `RewriteRule` replaces the root's, so the template repeats the
redirect.

Under COEP `require-corp` the page loads nothing from another origin that sends no CORS or CORP header.
Build a Flutter app with `--no-web-resources-cdn`, so CanvasKit comes from the app's own origin.

Suite `linux/scripts/tests/test-flutter-web-isolated-htaccess.sh` checks each directive, the guards, the
order of the two cache lines and the versioned-path patterns against sample paths. The
`docs-site.isolated-*` mutations prove it. After a publish, `check-live-site.js <app URL> --isolated`
checks the headers and `crossOriginIsolated` in Chrome:
[ftp-deploys.md § The live-site check](ftp-deploys.md#the-live-site-check).

`build-docs.yml` runs that check itself when the caller passes `live-url`. Its `live-check` job needs the
publish, so it never runs on a pull request. It pulls the family image for node and Chrome, takes the published
site, and runs `docs-site.sh live`. That checks every app, also after a red one, and fails if any is red. It refuses a
plain-http address, an empty app list and an app path outside the site.

## Staging ORT Web for an app

An app that runs ONNX Runtime in the browser ships the image's own ORT Web builds. Stage them in the
family image, in an amd64 job, before the link gate:

```bash
python3 -I linux/scripts/lib/stage-ort-web.py --out <site>/app [--jsep] [--no-js-bundles]
```

It reads `/usr/local/lib/onnxruntime-web` (`--source` changes it) and writes `ort/` below `--out`:

- One directory per build, `ort/<version>-<build hash>/`, in the order JSPI, Asyncify, CPU. `--jsep`
  adds JSEP last. The build hash is the first 16 hex digits of a SHA-256 over the build's file hashes, so
  new bytes get a new path. The isolated-app `.htaccess` marks only such a path immutable.
- Each directory holds the build's `.wasm`, its loader `.mjs`, its `ort.*.mjs` bundles, ORT's `LICENSE`
  and `ThirdPartyNotices.txt` and the probe's `ort-webgpu-factory-probe.LICENSE`. A `*.bak`, a source
  map or another build's bundle never ships.
- `ort/manifest.json` lists each build with its path, its build hash, every file with role, SHA-256 and
  size, and its receipt: the configured flags, the CMake cache hash and the factory probe's runtime
  receipt. It also names the ORT version, ref and revision, the image receipt's hash and where the
  license texts came from. `ort/manifest.json` itself keeps its name, so the app revalidates it.

| Build | Files | Bundles |
|---|---|---|
| JSPI | `ort-wasm-simd-threaded.jspi.{wasm,mjs}` | `ort.jspi*.mjs` |
| Asyncify | `ort-wasm-simd-threaded.asyncify.{wasm,mjs}` | `ort.webgpu*.mjs` |
| CPU | `ort-wasm-simd-threaded.{wasm,mjs}` | `ort.wasm*.mjs` |
| JSEP | `ort-wasm-simd-threaded.jsep.{wasm,mjs}` | `ort.mjs`, `ort.min.mjs`, `ort.bundle.min.mjs` |

**It refuses rather than ships fewer builds or other bytes.** Exit 1, and no `ort/` is written, when:

1. A requested build's `.wasm` or loader is missing, or its bundle is (pass `--no-js-bundles` where no
   bundle can exist: the image builds them on amd64 only).
2. A JSPI or Asyncify build has no flavor in `ort-webgpu-wasm.json`, or its bytes, its probe license or its
   runtime receipt differ from the receipt, or that runtime receipt records a failed probe.
3. ORT's license texts are neither beside the web output nor in an installed wheel of the receipt's ORT
   version, or a wheel's text differs from its `RECORD`. `--site-packages` names the wheel's directory;
   the default is the single `/opt/venv` one.
4. `<out>/ort` already exists.

The hashes of a build with a receipt come from the receipt, and the stager checks the bytes against them.
The image writes no receipt for CPU and JSEP, so their manifest entry says `"receipt": null` and every
hash there is of the bytes (`"hash_from": "bytes"`).

Suite `linux/scripts/tests/test-stage-ort-web.sh` covers the order, the file lists, the hashes, the
license sources and every refusal over fixture outputs. The `docs-site.ort-web-*` mutations prove it.

## Detector parity of the ORT Web builds

An app ships a staged build only if it detects what native ORT detects. Run the check in the family image
after staging:

```bash
python3 -I shared/python/ort_web_parity.py --site <site>/app --model deim_dfine_n_coco.onnx \
  --image two_cats.jpg --out <report dir> [--jsep] [--build NAME]... [--js-dir DIR]
```

The model is ModelANT's `deim_dfine_n_coco-v2` and the photo its `contracts/fixtures/two_cats.jpg`. Both are
checked by SHA-256. `linux/scripts/ort-web-parity-ci.sh <report dir> [--jsep]` stages the image's builds,
fetches both through `linux/scripts/lib/ort-web-parity.lock` and runs the check.

How it runs:

- The photo becomes one input tensor, stretched to 640x640 by nearest neighbour as OxidANT's `vision_core`
  does it. Native ORT and every build get the same bytes, so the report compares ORT builds, not decoders.
- Native ORT runs that tensor on `CPUExecutionProvider`. Its result must pass the comparator's two-cats
  baseline.
- `linux/scripts/ort-web-detector-parity.js` serves the site with COOP and COEP and drives headless Chrome.
  JSPI, Asyncify and JSEP run the `webgpu` provider on SwiftShader's WebGPU. CPU runs the `wasm` provider
  with `--disable-gpu`.
- The page imports the build's own `ort.*.min.mjs` with `wasmPaths` at the build's directory. It runs one
  session twice.

A build gets `"verdict": "ship"` when all four hold, else `"refuse"` with its reasons:

1. Its first run matches the native run within `compare_detector_parity.py`'s tolerances: the same count and
   classes, IoU 0.90 or more, scores within 0.05.
2. Its second run matches its first.
3. Each run finds at least two cats at 0.4 or more.
4. ORT placed nodes on the build's provider: `WebGpuExecutionProvider`, `JsExecutionProvider` or
   `CPUExecutionProvider`. ORT moves a node it cannot run to the CPU without a word.

The node counts come from the session's verbose log, because no profile file leaves the wasm.
`verify_ort_profile.py LOG.json --device webgpu --placements` applies the same rule to a JSON list of log
lines and prints each provider's share.

It exits 1 and writes no report when a requested build is not staged, a staged file differs from the
manifest, the model or the photo is another, or the report directory exists.

`<report dir>/<build>.json` holds the verdict, the reasons and the tolerances. It also holds the worst IoU and
score difference measured, the cats per run, the nodes and shares per provider, the operators placed elsewhere,
the Chrome version, the adapter and the times. `summary.json` lists the verdicts. Each run's detections sit
beside them in the comparator's format, and `<build>-page.json` keeps the page's answer with ORT's whole log.

`"decides": true` only when the page loaded the build's own bundle. The arm64 image has none, so `--js-dir` can
name the `ort.*.mjs` of the npm package of the same ORT version. Such a report proves the build's wasm and
loader, and decides nothing.

Workflow `ort-web-parity.yml` runs `ort-web-parity-ci.sh` in the amd64 image on a push to its files, on
Mondays and on dispatch, which can add `--jsep`. It uploads the reports as `ort-web-parity`, and they decide
which builds ship.

On a Pi 5 in the arm64 image, Chrome 157 on SwiftShader with two threads, against the npm package's JS of
ORT 1.31.1. These reports decide nothing:

| Build | Verdict | Worst IoU, score difference | Nodes on its provider | Session, first run, repeat |
|---|---|---|---|---|
| JSPI | refuse | none: the first run failed | 727 of 737 | 10.6 s, failed |
| Asyncify | ship | 0.999999, 0.00003 | 727 of 737 | 12.7 s, 219 s, 19 s |
| CPU | ship | 0.999999, 0.00002 | 717 of 717 | 1.8 s, 0.9 s, 0.5 s |
| JSEP | refuse | none: the first run failed | 760 of 773 | 5.0 s, failed |

- JSPI stopped in a `Conv2dMM` with `No cached or pending pipeline for deferred dispatch`. Three other runs of
  the JSPI build passed with Asyncify's numbers in about 210 s and 19 s. The failure is intermittent, so JSPI
  waits for the amd64 reports.
- JSEP stopped at a `MaxPool` with `ceil_mode`, which its WebGPU kernel does not implement, and it put `TopK`
  on the CPU. JSEP is no fallback for DEIM.
- On the WebGPU builds the ten CPU nodes are shape arithmetic: `Unsqueeze`, `Tile`, `Div`, `Mul`, `Sub` and
  `Cast`. `GridSample`, `GatherElements` and `TopK` ran on WebGPU.
- The first WebGPU run compiles every shader on SwiftShader, so the repeat takes a tenth of its time.

The deciding reports come from the amd64 image's own bundles, dispatch run 46103260764 on `b224ed00` with
Chrome 157 on SwiftShader:

| Build | Verdict | Worst IoU, score difference | Nodes on its provider | Session, first run, repeat |
|---|---|---|---|---|
| JSPI | ship | 0.999999, 0.000008 | 727 of 737 | 2.2 s, 38 s, 27 s |
| Asyncify | ship | 0.999999, 0.000008 | 727 of 737 | 2.5 s, 35 s, 27 s |
| CPU | ship | 0.999999, 0.00001 | 717 of 717 | 0.9 s, 0.3 s, 0.2 s |
| JSEP | refuse | none: the first run failed | 760 of 773 | failed |

- JSPI passed both runs on amd64; the Pi's `Conv2dMM` failure did not show.
- JSEP failed at the same `MaxPool` with `ceil_mode`. It runs only on request and never ships, so its report
  informs and the three shipping builds decide the job's exit. A run of JSEP alone still fails on its refusal.

Suite `linux/scripts/tests/test-ort-web-parity.sh` covers the verdicts, the tolerance edges, the cat rule, every
refusal and the report's shape over fixture builds, and the page and its server against a fake ORT module. The
`docs-site.ort-web-parity-*`, `docs-site.ort-web-harness-*` and `packaging.ort-profile-*` mutations prove it.
