#!/usr/bin/env bash
# requested-lanes.sh: the lanes in $LANES that the push's [ci <word>] tokens or $REQUEST's words ask for, as lanes= in $GITHUB_OUTPUT.
set -euo pipefail

messages=""
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
  # Every commit of the push, not only the head: a token in an earlier commit of a batch still counts.
  messages="$(jq -r '[.commits[]?.message, .head_commit.message?] | map(select(. != null)) | .[]' "${GITHUB_EVENT_PATH}")"
fi
lower() { tr '[:upper:]' '[:lower:]'; }
tokens="$(printf '%s\n' "${messages}" | lower | { grep -oE '\[ci [a-z0-9 ,_-]+\]' || true; } | sed -E 's/^\[ci //; s/\]$//')"
# The request is free text from a dispatch form: only lane-name characters survive.
request="$(printf '%s' "${REQUEST:-}" | lower | tr -c 'a-z0-9_-' ' ')"
words="$(printf '%s %s' "${tokens}" "${request}" | tr ',\n' '  ')"

chosen=" "
for lane in ${LANES}; do
  for word in ${words}; do
    if [ "${word}" = all ] || [[ "-${lane}-" == *"-${word}-"* ]]; then
      chosen+="${lane} "
      break
    fi
  done
done

for word in ${words}; do
  known=0
  [ "${word}" = all ] && known=1
  for lane in ${LANES}; do [[ "-${lane}-" == *"-${word}-"* ]] && known=1; done
  [ "${known}" = 1 ] || printf '::warning::[ci %s] names no lane here; the lanes are: %s\n' "${word}" "${LANES}"
done

printf 'requested lanes:%s\n' "${chosen% }"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'lanes=%s\n' "${chosen}" >> "${GITHUB_OUTPUT}"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf 'Requested lanes:%s\n' "${chosen% }" >> "${GITHUB_STEP_SUMMARY}"
