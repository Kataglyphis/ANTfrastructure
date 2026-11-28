#!/usr/bin/env bash
# verify-shipped-wrapper.sh over a stubbed nerdctl serving a real ELF libavcodec; not covered: a real export, pull or foreign-arch ELF.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../verify-shipped-wrapper.sh"

for _tool in cc strip readelf tar head; do t_skip_unless "${_tool}" command -v "${_tool}"; done
t_skip_unless "an ELF host compiler" t_is_elf "$(command -v cc)"
t_private_tmpdir

WORK="$(t_mktemp -d)"
_AVC=opt/ffmpeg/lib/libavcodec.so.61.3.100
_ORT=usr/lib/libonnxruntime.so.1
mkdir -p "${WORK}/rootfs/opt/ffmpeg/lib" "${WORK}/rootfs/usr/lib"
: > "${WORK}/rootfs/${_ORT}"
printf 'FFMPEG_ENABLE_TF=0\n' > "${WORK}/versions.env"
printf 'int avcodec_version(void) { return 61; }\n' > "${WORK}/avc.c"
cc -shared -fPIC -o "${WORK}/unstripped.so" "${WORK}/avc.c" || exit 1
cp "${WORK}/unstripped.so" "${WORK}/stripped.so" && strip --strip-all "${WORK}/stripped.so" || exit 1
_SIZE="$(wc -c < "${WORK}/unstripped.so")"

# The first export is the listing; a later one serves only EXPORT_BYTES of the same tar, as a stream that ended early.
cat > "${WORK}/nerdctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  image|rm) exit 0 ;;
  create) echo cid-fixture ;;
  export)
    n="$(cat "${STUB_DIR}/exports" 2>/dev/null || echo 0)"
    echo $((n + 1)) > "${STUB_DIR}/exports"
    if [ "${n}" -eq 0 ] || [ -z "${EXPORT_BYTES:-}" ]; then cat "${STUB_DIR}/export.tar"
    else head -c "${EXPORT_BYTES}" "${STUB_DIR}/export.tar"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${WORK}/nerdctl"

# _gate <libavcodec> [export bytes]: runs the gate over a rootfs shipping that libavcodec first, so its data starts at byte 512.
_gate() {
  cp "$1" "${WORK}/rootfs/${_AVC}"
  tar -cf "${WORK}/export.tar" -C "${WORK}/rootfs" "${_AVC}" "${_ORT}"
  rm -f "${WORK}/exports"
  local rc=0
  STUB_DIR="${WORK}" EXPORT_BYTES="${2:-}" NERDCTL_BIN="${WORK}/nerdctl" VERSIONS_ENV="${WORK}/versions.env" \
    bash "${SUBJECT}" img:runtime-amd64 amd64 > "${WORK}/out" 2>&1 || rc=$?
  printf 'rc=%s\n' "${rc}" >> "${WORK}/out"
}

t_case "an unstripped libavcodec fails the AP4 strip check"
_gate "${WORK}/unstripped.so"
t_assert_grep "${WORK}/out" 'FAIL AP4 strip NOT applied: libavcodec\.so\.61\.3\.100 still carries \.symtab'
t_assert_grep "${WORK}/out" '^rc=1$'

t_case "a stripped libavcodec passes it"
_gate "${WORK}/stripped.so"
t_assert_grep "${WORK}/out" 'OK  AP4 strip verified: libavcodec\.so\.61\.3\.100 has no \.symtab'
t_assert_grep "${WORK}/out" '^rc=0$'

t_case "an unstripped libavcodec cut short in the second export is skipped, never verified"
for _cut in 512 576 $((512 + _SIZE / 2)) $((512 + _SIZE - 64)); do
  _gate "${WORK}/unstripped.so" "${_cut}"
  t_assert_no_grep "${WORK}/out" 'AP4 strip verified'
  t_assert_grep "${WORK}/out" 'note AP4 strip check skipped'
  t_assert_grep "${WORK}/out" '^rc=0$'
done

t_summary
