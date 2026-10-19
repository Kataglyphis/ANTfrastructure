# Docs sites: build, check, publish

Every family repository publishes a documentation site to its own subdomain of the
FTP host (Apache, one docroot per site). This page owns what the hub does to a built
site before it goes up. The upload itself is
[`deploy-over-ftp`](ftp-deploys.md).

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
