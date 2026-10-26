#!/usr/bin/env bash
# Tests create parseable ELF64 dynamic sections without a compiler or target sysroot.

# t_write_synthetic_elf <python> [--strsz] [--symbol STYLE:SHNDX] <path> <needed,csv> <runpath> [text]...
t_write_synthetic_elf() {
  local PYTHON="${1:?Python interpreter required}" include_strsz=0 symbol_spec='' output host_dir
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --strsz) include_strsz=1; shift ;;
      --symbol)
        [ "$#" -ge 2 ] || { printf 'ELF fixture: --symbol needs STYLE:SHNDX\n' >&2; return 2; }
        symbol_spec="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -ge 3 ] || { printf 'ELF fixture: path, needed and runpath are required\n' >&2; return 2; }
  output="$1"
  mkdir -p "$(dirname "$output")" || return
  host_dir="$(cd "$(dirname "$output")" && { pwd -W 2>/dev/null || pwd; })" || return
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PYTHON}" - "$host_dir/$(basename "$output")" "$include_strsz" "$symbol_spec" "${@:2}" <<'PY'
import struct
import sys

path, strsz_text, symbol_spec, needed, runpath, *texts = sys.argv[1:]
include_strsz = strsz_text == "1"
style, _, shndx = symbol_spec.partition(":")
strtab, dyn, syms = b"\0", [], b""
for tag, value in [(1, name) for name in needed.split(",") if name] + (
    [(29, runpath)] if runpath else []
):
    dyn.append((tag, len(strtab)))
    strtab += value.encode() + b"\0"
if style:
    h = 5381
    for char in b"OrtGetApiBase":
        h = (h * 33 + char) & 0xFFFFFFFF
    if style == "gnu":
        table = struct.pack("<IIIIQII", 1, 1, 1, 6, 2**64 - 1, 1, h | 1)
    elif style == "sysv":
        table = struct.pack("<IIIII", 1, 2, 1, 0, 0)
    else:
        raise ValueError(f"unsupported ELF symbol style: {style}")
    syms = b"\0" * 24 + struct.pack(
        "<IBBHQQ", len(strtab), 0x12, 0, int(shndx), 0x1000 if int(shndx) else 0, 0
    ) + table
    strtab += b"OrtGetApiBase\0"
dyn_off = 64 + 2 * 56
dyn_size = 16 * (len(dyn) + 2 + include_strsz + (3 if style else 0))
str_off = dyn_off + dyn_size + len(syms)
if style:
    dyn += [
        (6, dyn_off + dyn_size),
        (11, 24),
        (0x6FFFFEF5 if style == "gnu" else 4, dyn_off + dyn_size + 48),
    ]
payload = b"".join(b"\0" + text.encode() + b"\0" for text in texts)
total = max(str_off + len(strtab) + len(payload), 2048)
data = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
data += struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 64, 0, 0, 64, 56, 2, 64, 0, 0)
data += struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, total, total, 0x1000)
data += struct.pack("<IIQQQQQQ", 2, 6, dyn_off, dyn_off, dyn_off, dyn_size, dyn_size, 8)
data += b"".join(struct.pack("<qQ", tag, value) for tag, value in dyn)
data += struct.pack("<qQ", 5, str_off)
if include_strsz:
    data += struct.pack("<qQ", 10, len(strtab))
data += struct.pack("<qQ", 0, 0)
data += syms + strtab + payload
with open(path, "wb") as output:
    output.write(data + b"\0" * (total - len(data)))
PY
}
