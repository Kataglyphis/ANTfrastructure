# Flutter: cherry-pick the libunwind symbol fix to stable and beta

**Posted on 2026-11-27 with the owner's approval**, the comment below with its paragraphs unwrapped:
<https://github.com/flutter/flutter/issues/196402#issuecomment-7222133675>. Watch #196451 for the
`cp: stable` and `cp: beta` labels; the manual PR fields at the end stay the fallback.

| | |
|---|---|
| Upstream | flutter/flutter |
| Kind | cherry-pick request: a comment on #196402, or the fields of a manual cherry-pick PR |
| The fix | #196451, merged to master on 2026-11-20 as `203c0c42cf8f572ac3158d21bb24089c4d91dfb2` |
| Still missing from | 3.50.1 (engine `4d35714800b9266b6693a58e1225ecd7e9e45ed7`), stable `flutter-3.50-candidate.0`, beta `flutter-3.51-candidate.0` |
| Hub record | [`docs/failure-modes.md`](../../../docs/failure-modes.md#a-flutter-350-linux-app-aborts-at-its-first-c-exception) |

## Why a cherry-pick, not a new issue

The bug is filed and fixed on master. #196402 reports the C++ case, and #197043 (the Rust case) was
closed as its duplicate. #196451 closed both. A new issue would be closed as a duplicate too.

Flutter's [cherry-pick process](https://github.com/flutter/flutter/blob/master/docs/releases/Flutter-Cherrypick-Process.md)
lets anyone ask. The automatic route is a `cp: stable` or `cp: beta` label on the merged PR. Adding a
label needs triage rights, so the comment below asks a maintainer to add them. #196451's merge
commit carries `.github/workflows/cp-trigger.yml`, so the label works for it. If the automatic
cherry-pick conflicts, a manual PR to the candidate branch needs the six fields at the end.

## Before posting

Upstream moves. Run all three again:

```sh
# 1. The current candidate branches (stable and beta).
for ch in stable beta; do
  gh api "repos/flutter/flutter/contents/bin/internal/release-candidate-branch.version?ref=$ch" --jq .content | base64 -d
done

# 2. Is the fix still missing there? "diverged" or "behind" means missing; "ahead" or "identical" means present.
gh api repos/flutter/flutter/compare/203c0c42cf8f572ac3158d21bb24089c4d91dfb2...flutter-3.50-candidate.0 --jq .status

# 3. Has someone asked already? Read #196451's and #196402's comments, and search for a cherry-pick PR.
gh search prs --repo flutter/flutter "Hide libunwind symbols"
```

On 2026-11-27 step 2 printed `diverged` for both candidate branches and for 3.50.1's engine commit,
and step 3 found only #196451 itself.

## Comment to post on #196402

---

3.50.1 still ships the exported unwinder, so this still aborts apps on stable. #196451 is on master
only: its merge commit `203c0c42` is on neither `flutter-3.50-candidate.0` (stable) nor
`flutter-3.51-candidate.0` (beta), and 3.51.0-0.2.pre does not have it either.

Could someone with triage rights add `cp: stable` and `cp: beta` to #196451? Its merge commit
already carries `cp-trigger.yml`.

What 3.50.1 exports (`linux-x64-release` and `linux-x64-debug` from
`storage.googleapis.com/flutter_infra_release/flutter/<engine>/`):

```console
$ nm -D --defined-only libflutter_linux_gtk.so | grep -E -c '_Unwind_|unw_|register_frame'
0     # 3.47.9, engine 89c39edfdfae2949f6806e4a315c0c08522238b7
31    # 3.50.1, engine 4d35714800b9266b6693a58e1225ecd7e9e45ed7
```

The 31 are ten `_Unwind_*` functions (`_Unwind_DeleteException`, `_Unwind_ForcedUnwind`,
`_Unwind_GetGR`, `_Unwind_GetIP`, `_Unwind_GetLanguageSpecificData`, `_Unwind_GetRegionStart`,
`_Unwind_RaiseException`, `_Unwind_Resume`, `_Unwind_SetGR`, `_Unwind_SetIP`), four `__unw_*`
(`__unw_add_dynamic_eh_frame_section`, `__unw_add_dynamic_fde` and their two `remove` twins) and
seventeen `unw_*`. `_Unwind_GetIPInfo` and `_Unwind_Backtrace` are not exported, so they still come
from libgcc_s.

Smallest reproduction, no Flutter project needed (`repro.cc`):

```cpp
#include <cstdio>
#include <stdexcept>

int main() {
  try {
    throw std::runtime_error("caught");
  } catch (const std::exception &e) {
    std::puts(e.what());
  }
}
```

```sh
ENGINE=<dir with libflutter_linux_gtk.so>
# The engine first in NEEDED, as in a Flutter runner:
g++ -o flutter-first repro.cc -Wl,--no-as-needed -L"$ENGINE" -lflutter_linux_gtk -Wl,-rpath,"$ENGINE"
# libgcc_s first:
g++ -o gcc-first repro.cc -Wl,--no-as-needed -lgcc_s -L"$ENGINE" -lflutter_linux_gtk -Wl,-rpath,"$ENGINE"
```

| Engine | `flutter-first` | `gcc-first` |
|---|---|---|
| 3.50.1 release | `terminate called after throwing an instance of 'std::runtime_error'`, `terminate called recursively`, SIGABRT (134) | prints `caught` |
| 3.50.1 debug | the same abort | prints `caught` |
| 3.47.9 release | prints `caught` | prints `caught` |

Ubuntu, GCC 15.2, x86_64. In a real app the core's stack is `__cxa_throw` →
`_Unwind_RaiseException` (`libflutter_linux_gtk.so`) → `__gxx_personality_v0` →
`__cxa_call_terminate`, for an exception the throwing library catches itself.

The workaround every Linux app needs until a release carries the fix, in `linux/CMakeLists.txt`
before the runner links `flutter`:

```cmake
target_link_libraries(${BINARY_NAME} PRIVATE "-Wl,--push-state,--no-as-needed" gcc_s "-Wl,--pop-state")
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
```

Expected: the engine exports none of libunwind's symbols. #196451 does that with
`-Wl,--exclude-libs,libunwind.a`; hidden visibility for the statically linked libunwind would do
the same.

---

## Fields for a manual cherry-pick PR

Only if the label route fails. Title `[stable] [Linux] Hide libunwind symbols in libflutter_linux_gtk.so (#196451)`
against `flutter-3.50-candidate.0`, and the same with `[beta]` against `flutter-3.51-candidate.0`.
Then the `cp: review` label. A PR needs Google's CLA; a comment does not.

- **Impacted Users:** every Linux desktop app on 3.50 that runs C++ or Rust code which throws,
  panics or captures a backtrace, plugins included. Examples from #196402 and #197043:
  `flutter_secure_storage_linux` without an unlocked keyring, flutter_rust_bridge's errors, and
  media_kit over a LuaJIT mpv.
- **Impact Description:** the app crashes at the first exception, even one the library catches:
  SIGABRT for C++ and a Rust panic, SIGSEGV for a Rust backtrace. Release builds crash too, so
  shipped apps are affected.
- **Workaround:** link `libgcc_s` ahead of the engine in each app's `linux/CMakeLists.txt` (above).
  Every app has to find and apply it itself.
- **Risk:** low. One linker flag on one shared library; libunwind stays statically linked and
  becomes private. Master has carried it since 2026-11-20.
- **Test Coverage:** #196451 adds `--forbid-exported-unwind-symbols` to
  `check_forbidden_native_symbols`, on for Linux.
- **Validation Steps:** `nm -D --defined-only libflutter_linux_gtk.so | grep -E '_Unwind_|unw_|register_frame'`
  prints nothing for debug, profile and release, and the ten-line program above prints `caught`
  with the engine first in NEEDED.

## Verified, and not

Verified on 2026-11-27:

- The symbol counts, on both engines, release and debug. Zip sha256: 3.50.1 release
  `aac268d6421af245e9ce03f371e846ad2e6b6aa8a91333a2f9a78a8c119ac54d`, debug
  `b1d5701aac2944005b96872e768201d5ceb7e3f90d99acd34e827f5db8fd62de`; 3.47.9 release
  `30ab0801fddfa1c208f5c3ddb5cce6256ad751c1e25b428d4de09e80869f34d9`, debug
  `9e333f37446a702d7415ae98ff23278e21ccc01714862f4294bf91a70aed8af0`.
- The reproduction's three rows, in WSL Ubuntu 26.04.
- That `203c0c42` is not reachable from 3.50.1's engine commit, from either candidate branch or
  from 3.51.0-0.2.pre (GitHub's compare API), and that its merge commit carries `cp-trigger.yml`.

Not verified:

- That `203c0c42` cherry-picks cleanly onto either candidate branch.
- An engine built with the fix. #197043's author built 3.50.0 with the same flag, on x86_64 only.
- The `linux-arm64` artifacts' symbols. OmniAccelerANT's arm64 lane aborts the same way, but the
  arm64 engine was not run through `nm` here.
