#!/usr/bin/env bash
# oci-layers-extract.py and riscv64-sysroot.sh --mode skopeo over synthetic layered images. See docs/riscv64-cross-test-lanes.md#the-sysroot-from-the-registry-skopeo
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
EXTRACT="${SCRIPTS_DIR}/02-toolchain/oci-layers-extract.py"
SYSROOT_SH="${SCRIPTS_DIR}/02-toolchain/riscv64-sysroot.sh"

t_skip_unless "a POSIX python3 with real symlinks" t_posix_python
t_skip_unless "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT
umask 022

# _layout <dir> <scenario> [link target]: a skopeo dir: layout whose layers the scenario's Python writes, bottom first.
_layout() {
  python3 - "$@" <<'PY'
import hashlib, io, json, os, sys, tarfile
out, scenario = sys.argv[1], sys.argv[2]
os.makedirs(out)
layers = []

def layer(entries, compress="gz"):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:" + compress if compress else "w") as tar:
        for e in entries:
            ti = tarfile.TarInfo(e[0])
            kind, ti.mtime = e[1], 1700000000
            ti.mode = e[3] if len(e) > 3 else (0o755 if kind in ("dir", "sym") else 0o644)
            data = b""
            if kind == "dir":
                ti.type = tarfile.DIRTYPE
            elif kind == "sym":
                ti.type, ti.linkname = tarfile.SYMTYPE, e[2]
            elif kind == "hard":
                ti.type, ti.linkname = tarfile.LNKTYPE, e[2]
            elif kind == "dev":
                ti.type = tarfile.CHRTYPE
            else:
                data = e[2].encode()
                ti.size = len(data)
            tar.addfile(ti, io.BytesIO(data))
    blob = buf.getvalue()
    digest = hashlib.sha256(blob).hexdigest()
    with open(os.path.join(out, digest), "wb") as fh:
        fh.write(blob)
    layers.append({"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": "sha256:" + digest, "size": len(blob)})

if scenario == "stack":
    layer([("usr", "dir"), ("usr/lib", "dir"), ("usr/lib/x", "dir"), ("usr/bin", "dir"),
           ("usr/lib/x/a.so", "file", "a1"), ("usr/lib/x/b.so", "file", "b1"),
           ("usr/lib/x/sub", "dir"), ("usr/lib/x/sub/c.txt", "file", "c1"),
           ("usr/lib/x/link.so", "sym", "a.so"), ("usr/lib/x/abs", "sym", "/usr/lib/x/a.so"),
           ("usr/lib/x/hard", "hard", "usr/lib/x/a.so"), ("usr/lib/x/suid", "file", "s", 0o4755),
           ("usr/lib/x/wide", "file", "w", 0o777), ("usr/lib/x/private", "dir", None, 0o700),
           ("usr/bin/tool", "file", "tool-bytes", 0o755), ("usr/lib/x/tool-hard", "hard", "usr/bin/tool"),
           ("usr/share/doc/readme", "file", "not allowlisted"), ("lib", "sym", "usr/lib"),
           ("opt/gcc/bin/gcc", "file", "g", 0o755), ("opt/gcc/lib/libstdc++.so.6", "file", "l"),
           ("etc/ld.so.cache", "file", "cache")])
    layer([("usr/lib/x/.wh.b.so", "file", ""), ("usr/lib/x/sub/.wh..wh..opq", "file", ""),
           ("usr/lib/x/sub/d.txt", "file", "d2"), ("usr/lib/x/a.so", "file", "a2"),
           ("usr/lib/x/link.so", "file", "now a file"), ("usr/share/.wh.doc", "file", ""),
           (".wh.opt", "file", ""), ("opt/gcc/lib/new.so", "file", "n2")])
    layer([("usr/lib/x/later", "file", "plain tar")], compress="")
    layers.append(layers[-1])
elif scenario == "climb":
    layer([("usr/lib/x/ok", "file", "1"), ("usr/lib/x/../../../../escape", "file", "2")])
elif scenario == "through-link":
    layer([("usr/lib/x/esc", "sym", sys.argv[3] if len(sys.argv) > 3 else "/nonexistent")])
    layer([("usr/lib/x/esc/pwned", "file", "3")])
elif scenario == "same-layer-link":
    layer([("usr/lib/x/esc", "sym", "/tmp"), ("usr/lib/x/esc/pwned", "file", "3")])
elif scenario == "device":
    layer([("usr/lib/x/null", "dev")])
json.dump({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "layers": layers},
          open(os.path.join(out, "manifest.json"), "w"))
PY
}

_run() { python3 -I "${EXTRACT}" "$@"; }

# _is <path under the tree> <content> <why>, _stat <path> <stat format> <value> <why>: one assertion each on the stack's tree.
S1="${_tmp}/s1"
_is() { t_assert_eq "$2" "$(cat "${S1}/$1")" "$3"; }
_stat() { t_assert_eq "$3" "$(stat -c "$2" "${S1}/$1")" "$4"; }

t_case "layers apply in order: whiteouts, opaque dirs, replacements and the last layer win"
_layout "${_tmp}/stack" stack
_out="$(_run --layout "${_tmp}/stack" --dest "${S1}" --jobs 2 usr/lib/x lib opt/gcc etc/ld.so.cache 2>&1)"; _rc=$?
t_assert_eq 0 "${_rc}" "a well-formed four-layer stack must extract: ${_out}"
t_assert_contains "${_out}" "4 layers" "the summary counts every layer position, the repeated blob included"
_is usr/lib/x/a.so a2 "an upper layer's file replaces the lower one"
t_assert_fails test -e "${S1}/usr/lib/x/b.so"
t_assert_fails test -e "${S1}/usr/lib/x/sub/c.txt"
_is usr/lib/x/sub/d.txt d2 "an opaque dir keeps its own layer's entries"
_is usr/lib/x/link.so "now a file" "a file replaces a lower symlink, it is not written through it"
t_assert_fails test -L "${S1}/usr/lib/x/link.so"
_is usr/lib/x/later "plain tar" "an uncompressed layer is read too"

t_case "a whiteout of an ancestor removes the allowlisted tree below it"
t_assert_fails test -e "${S1}/opt/gcc/bin/gcc"
_is opt/gcc/lib/new.so n2 "the whiting layer's own entries are not hidden"

t_case "links, modes and the allowlist match a non-root GNU tar"
t_assert_eq "/usr/lib/x/a.so" "$(readlink "${S1}/usr/lib/x/abs")" "symlinks keep their target; riscv64-sysroot.sh relativizes"
t_assert_eq "usr/lib" "$(readlink "${S1}/lib")" "the merged-usr link is a link, not a copy"
_is usr/lib/x/hard a1 "a hard link keeps the content of its layer, not a later replacement"
_is usr/lib/x/tool-hard tool-bytes "a hard link to a path outside the allowlist gets the target's bytes"
_stat usr/lib/x/suid %a 755 "setuid is dropped, as tar does for a non-root user"
_stat usr/lib/x/wide %a 755 "the umask applies to file modes"
_stat usr/lib/x/private %a 700 "a directory keeps its own mode"
_stat usr/lib/x/a.so %Y 1700000000 "file mtimes come from the layer"
t_assert_fails test -e "${S1}/usr/bin/tool"
t_assert_fails test -e "${S1}/usr/share"
t_assert_ok test -f "${_tmp}/stack/manifest.json"

t_case "--delete-blobs unlinks each blob once its last layer position is applied"
_run --layout "${_tmp}/stack" --dest "${_tmp}/s2" --jobs 1 --delete-blobs usr/lib/x >/dev/null 2>&1; _rc=$?
t_assert_eq 0 "${_rc}" "a blob listed twice must still be there for its second position"
t_assert_eq "1" "$(find "${_tmp}/stack" -type f | wc -l | tr -d ' ')" "only manifest.json is left"
t_assert_fails test -e "${_tmp}/s2.layers"

# _try <scenario> [link target]: extracts usr/lib/x from the scenario into <scenario>.out; sets _out and _rc.
_try() {
  _layout "${_tmp}/$1" "$@"
  _out="$(_run --layout "${_tmp}/$1" --dest "${_tmp}/$1.out" usr/lib/x 2>&1)"; _rc=$?
}
# _refused <message part> <why>: the last _try exited 1 and said why.
_refused() {
  t_assert_eq 1 "${_rc}" "$2"
  t_assert_contains "${_out}" "$1" "the error names the cause"
}

t_case "a path missing from the image fails, as tar's 'Not found in archive' does"
_layout "${_tmp}/stack2" stack
_out="$(_run --layout "${_tmp}/stack2" --dest "${_tmp}/s3" usr/lib/x opt/vulkan 2>&1)"; _rc=$?
_refused "not in the image: opt/vulkan" "a sysroot without an allowlisted prefix must stop the lane"

t_case "nothing is ever written outside the destination"
_try climb
_refused "climbs out of the image root" "a '..' member must fail the extract"
t_assert_eq "" "$(find "${_tmp}" -name escape)" "the member must not land anywhere, inside or outside"
mkdir -p "${_tmp}/outside"
_try through-link "${_tmp}/outside"
t_assert_eq 0 "${_rc}" "an upper layer's directory replaces a lower symlink: ${_out}"
t_assert_eq "" "$(ls -A "${_tmp}/outside")" "a lower symlink to a host path must not receive the upper layer's files"
t_assert_eq "3" "$(cat "${_tmp}/through-link.out/usr/lib/x/esc/pwned")" "the file lands in a real directory inside the destination"
_try same-layer-link
_refused "not a directory" "a member under a symlink of its own layer is refused"
t_assert_fails test -e /tmp/pwned

t_case "a device node fails, as an unprivileged tar does"
_try device
_refused "cannot be written unprivileged" "a device in the allowlist must stop the extract"

t_case "a non-empty destination or a missing blob is refused"
mkdir -p "${_tmp}/full" && : > "${_tmp}/full/x"
t_assert_fails _run --layout "${_tmp}/stack" --dest "${_tmp}/full" usr/lib/x
t_assert_fails _run --layout "${_tmp}/nolayout" --dest "${_tmp}/w" usr/lib/x

t_case "riscv64-sysroot.sh --mode skopeo fetches the pinned child and extracts the allowlist"
_bin="${_tmp}/bin"
mkdir -p "${_bin}"
cat > "${_bin}/skopeo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "${_tmp}/skopeo.args"
for a in "\$@"; do case "\$a" in dir:*) cp -r "${_tmp}/stack-src" "\${a#dir:}" ;; esac; done
EOF
chmod +x "${_bin}/skopeo"
_layout "${_tmp}/stack-src" stack
_out="$(RISCV64_SYSROOT_SKOPEO="${_bin}/skopeo" bash -c "source '${SYSROOT_SH}'; RISCV64_SYSROOT_PATHS=(usr/lib/x lib); EXTRA_PATHS=(); skopeo_child ghcr.io/k/img@sha256:rv '${_tmp}/k'" 2>&1)"; _rc=$?
t_assert_eq 0 "${_rc}" "the skopeo path must build the tree: ${_out}"
t_assert_contains "$(cat "${_tmp}/skopeo.args")" "docker://ghcr.io/k/img@sha256:rv dir:${_tmp}/k.layout" \
  "the fetch must name the riscv64 child by digest, so it matches the amd64 image's index"
t_assert_eq "a2" "$(cat "${_tmp}/k/usr/lib/x/a.so")" "the extract applied every layer"
t_assert_fails test -e "${_tmp}/k.layout"
_out="$(RISCV64_SYSROOT_SKOPEO="${_tmp}/none/skopeo" bash -c "source '${SYSROOT_SH}'; skopeo_child r@sha256:x '${_tmp}/m'" 2>&1)"; _rc=$?
t_assert_eq 1 "${_rc}" "no skopeo must stop the lane, not fall back"
t_assert_contains "${_out}" "--mode export" "the error names the other mode"

t_case "riscv64-sysroot.sh takes export or skopeo and nothing else"
t_assert_eq "skopeo" "$(bash -c "source '${SYSROOT_SH}'; parse_args --dest /x --mode skopeo; printf '%s' \"\${MODE}\"")" "--mode reaches MODE"
t_assert_eq "export" "$(bash -c "source '${SYSROOT_SH}'; parse_args --dest /x; printf '%s' \"\${MODE}\"")" "export stays the default for a host with only an engine"
t_assert_fails bash -c "source '${SYSROOT_SH}'; parse_args --dest /x --mode pull"

t_summary
