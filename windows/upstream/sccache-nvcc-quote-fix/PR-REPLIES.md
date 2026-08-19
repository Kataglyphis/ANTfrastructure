# Local drafts for PR #2811 replies (OWNER posts - Claude drafts only, per
# owner directive 2026-08-19)

## Re: does this fix #2470? (POSTED 2026-08-19 by Claude before the
## drafts-only directive - kept here as the record)

Yes - reproduced and verified A/B. #2470 is the odd-parity presentation of
the same bug: `-DCMAKE_INTDIR=\"Release\"` (added by Ninja Multi-Config,
absent in single-config - matching the reporter's "msvc-x64 preset works")
loses its `\"` escapes in the pre-tokenization backslash flatten. With an
ODD resulting quote count `shlex::split` returns None -> the fatal "Could
not parse shell line"; with an EVEN count it silently mis-groups (the
dropped-instantiation miscompile this PR was filed for).

Measured (Windows, CUDA 13.3, single nvcc command with that define):
* sccache v0.17.0 release: exit -2, "Could not parse shell line"
* with this PR's fix: exit 0, decomposition executes and caches (5 steps)
