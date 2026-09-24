#!/usr/bin/env bash
# windows/scripts/patches/ffmpeg/makedef writes the EXPORTS list of every FFmpeg
# DLL from a version script's globs and the objects' llvm-nm dump. It emitted an
# EMPTY list twice without a word -- the second time on the rocm lane
# (2026-09-24), where avutil-61.dll exported nothing and swresample, swscale and
# the rest then failed to link on undefined av_* symbols. The stub llvm-nm below
# prints each fake object's own content, so this runs on any host.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MAKEDEF="${TESTS_DIR}/../../../windows/scripts/patches/ffmpeg/makedef"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
cd "${_work}" || exit 1

# nm-format fake objects: <value> <type> <name>, as `llvm-nm --defined-only -g` prints.
printf '0000000000000000 T av_alpha\n0000000000000010 T ff_hidden\n' > a.o
printf '0000000000000000 T av_beta\n0000000000000000 D av_gamma_table\n' > b.o
printf '0000000000000000 T _av_prefixed\n' > p.o
printf 'a.o\nb.o\n' > objs.rsp
printf 'LIBAVUTIL_61 {\n    global:\n        av*;\n    local:\n        *;\n};\n' > libavutil.ver
printf 'LIBZZ_1 {\n    global: zz*;\n    local: *;\n};\n' > nomatch.ver

mkdir -p stub bin
# The stub: record its argv, then print every object's content -- a plain argument
# or each line of an @response-file, which is how LLVM tools take long lists.
cat > stub/fake-nm <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_NM_ARGV:-/dev/null}"
for f in "$@"; do
  case "$f" in
    -*) ;;
    @*) while IFS= read -r o; do [ -n "$o" ] && cat "$o"; done < "${f#@}" ;;
    *) cat "$f" ;;
  esac
done
STUB
# A broken nm: says why on stderr and lists nothing.
printf '#!/usr/bin/env bash\necho "fake-nm: a.o: unsupported file format" >&2\nexit 1\n' > stub/broken-nm
cp stub/fake-nm bin/llvm-nm
chmod +x stub/fake-nm stub/broken-nm bin/llvm-nm

_makedef() { LLVM_NM="${_work}/stub/fake-nm" EXTERN_PREFIX="" sh "${MAKEDEF}" "$@"; }

t_case "a response file and a plain object both reach llvm-nm; only the version script's globs are exported"
_out="$(_makedef libavutil.ver @objs.rsp p.o 2>&1)"
t_assert_eq "0" "$(t_rc _makedef libavutil.ver @objs.rsp p.o)"
t_assert_eq "EXPORTS" "$(printf '%s\n' "${_out}" | head -1)"
t_assert_contains "${_out}" "    av_alpha" "an object named in the response file"
t_assert_contains "${_out}" "    av_gamma_table" "a data symbol matches the glob too"
t_assert_fails grep -q -e 'ff_hidden' <<<"${_out}"

t_case "the object list reaches llvm-nm as one @response-file, never on a command line"
# xargs carried it, and on the rocm lane (2026-09-24) aborted before llvm-nm ran:
# 'assertion "bc_ctl.arg_max >= LINE_MAX" failed', its environment too large.
rm -f argv.txt
FAKE_NM_ARGV="${_work}/argv.txt" _makedef libavutil.ver @objs.rsp p.o >/dev/null 2>&1
t_assert_eq "1" "$(grep -c . argv.txt)" "one llvm-nm run for the whole list"
t_assert_contains "$(cat argv.txt)" "@libavutil.ver.nm-objects"
t_assert_fails grep -q -e 'a\.o' argv.txt
t_assert_eq "$(printf 'a.o\nb.o\np.o')" "$(cat libavutil.ver.nm-objects)" "one object per line, response-file args expanded"

t_case "LLVM_NM names the llvm-nm to run; a bare llvm-nm on PATH is only the fallback"
_out="$(LLVM_NM="${_work}/stub/broken-nm" PATH="${_work}/bin:${PATH}" EXTERN_PREFIX="" sh "${MAKEDEF}" libavutil.ver a.o 2>&1)"
t_assert_contains "${_out}" "fake-nm: a.o: unsupported file format" "LLVM_NM must win over PATH"
_out="$(env -u LLVM_NM PATH="${_work}/bin:${PATH}" EXTERN_PREFIX="" sh "${MAKEDEF}" libavutil.ver a.o 2>&1)"
t_assert_contains "${_out}" "    av_alpha" "unset, the llvm-nm on PATH is used"

t_case "an nm that lists nothing is refused, with its stderr, and no EXPORTS line is written"
_rc="$(LLVM_NM="${_work}/stub/broken-nm" EXTERN_PREFIX="" sh "${MAKEDEF}" libavutil.ver a.o >stdout.txt 2>stderr.txt; echo $?)"
t_assert_eq "1" "${_rc}" "an empty dump must fail the make recipe"
t_assert_contains "$(cat stderr.txt)" "listed no global symbol in 1 object(s)"
t_assert_contains "$(cat stderr.txt)" "fake-nm: a.o: unsupported file format" "the nm's own error is the evidence"
t_assert_eq "" "$(cat stdout.txt)" "stdout is the .def file; nothing may reach it"

t_case "globs that match no symbol are refused, not written as an empty EXPORTS list"
_rc="$(_makedef nomatch.ver a.o >stdout.txt 2>stderr.txt; echo $?)"
t_assert_eq "1" "${_rc}"
t_assert_contains "$(cat stderr.txt)" "no global symbol matches the patterns of nomatch.ver"
t_assert_eq "" "$(cat stdout.txt)"

t_case "EXTERN_PREFIX is stripped before matching"
_out="$(LLVM_NM="${_work}/stub/fake-nm" EXTERN_PREFIX="_" sh "${MAKEDEF}" libavutil.ver p.o 2>&1)"
t_assert_contains "${_out}" "    av_prefixed"

t_summary
