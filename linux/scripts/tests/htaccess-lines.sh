#!/usr/bin/env bash
# Reads an .htaccess template line by line for the htaccess suites; HTACCESS names the file. See docs/docs-sites.md#the-sites-htaccess

# Byte order for every sort, so a host's locale cannot reorder a list the suites compare.
export LC_ALL=C

# The override classes' directives the host is proven to allow: FileInfo, nothing else.
# shellcheck disable=SC2034  # read by the suites that source this file
HTACCESS_FILEINFO='<IfModule|</IfModule>|RewriteEngine|RewriteCond|RewriteRule|Header|RedirectMatch|AddType|AddOutputFilterByType|ErrorDocument|SetEnvIf'

# _directives: each directive name the file uses, one per line; a container tag counts as <IfModule.
_directives() { sed -E 's/^[[:space:]]+//' "${HTACCESS}" | grep -vE '^(#|$)' | awk '{ print $1 }' | sort -u; }
# _line <ERE>: the one line matching it, leading blanks dropped; empty when none.
_line() { sed -E 's/^[[:space:]]+//' "${HTACCESS}" | grep -E "$1" | head -n 1; }
# _guards <ERE>: the modules of every <IfModule> around the first line matching it, sorted, one line.
_guards() {
  sed -E 's/^[[:space:]]+//' "${HTACCESS}" | awk -v re="$1" '
    /^<IfModule / { n++; m[n] = $2; sub(/>$/, "", m[n]); next }
    /^<\/IfModule>/ { n--; next }
    $0 ~ re { for (i = 1; i <= n; i++) print m[i]; exit }' | sort | paste -sd' ' -
}
# _matches <regex> <path>: 1 when Python's re finds it, else 0; through stdin, as Git Bash rewrites a /path argument.
_matches() {
  printf '%s\n%s\n' "$1" "$2" |
    "${PREFLIGHT_PYTHON:-python3}" -c 'import re, sys; r, s = sys.stdin.read().split("\n")[:2]; print(1 if re.search(r, s) else 0)'
}
