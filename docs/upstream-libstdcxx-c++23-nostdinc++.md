# Upstreaming: add `-nostdinc++` to libstdc++ `src/c++23` (Canadian-cross `std` module)

This documents the **upstream** form of the fix we carry downstream in
`linux/scripts/02-toolchain/build-gcc.sh`. Our build patches the pre-generated
`Makefile.in` at build time (no autotools needed in-container); upstream wants the
change in the *source* `Makefile.am` plus a regenerated `Makefile.in`.

Related upstream bugs: **PR libstdc++/100017**, **PR libstdc++/101060**
(Canadian-cross `#include_next <fenv.h>` picks up the host libstdc++ wrapper,
guard-collides on `_GLIBCXX_FENV_H`, so libc `<fenv.h>` is never reached).

## Root cause (one paragraph)

In a Canadian cross (`build` != `host` == `target`) the host g++'s libstdc++
headers are on the search path. libstdc++'s `<fenv.h>` wrapper
(`c_compatibility/fenv.h`) guards itself with `_GLIBCXX_FENV_H` and does
`#include_next <fenv.h>` to reach the libc header. When the target wrapper sets
`_GLIBCXX_FENV_H` then `#include_next` lands on the *host* wrapper, that wrapper is
guard-skipped, so its own `#include_next` never fires and the libc `<fenv.h>` is
never included — `::fenv_t` and every `fe*` become undeclared. The fix used
everywhere else in libstdc++ is `-nostdinc++`, which keeps the host C++ headers off
the search path. It is present in `src/c++17/Makefile.am` (that was the PR100017
fix) but was **never propagated** to `src/c++23`, which builds the C++23
`std`/`std.compat` modules from `std.cc`. Result: the module compile fails and
libstdc++'s recipe silently ships an **empty** module
(`stamp-modules-bits ... Error 1 (ignored)`). Also observed on native Apple
Silicon (Homebrew homebrew-core#289142).

## The patch (against GCC `master` / `releases/gcc-16`)

```diff
--- a/libstdc++-v3/src/c++23/Makefile.am
+++ b/libstdc++-v3/src/c++23/Makefile.am
@@ AM_CXXFLAGS
 AM_CXXFLAGS = \
-	-std=gnu++23 \
+	-std=gnu++23 -nostdinc++ \
 	$(glibcxx_lt_pic_flag) $(glibcxx_compiler_shared_flag) \
 	$(XTEMPLATE_FLAGS) $(VTV_CXXFLAGS) \
 	$(WARN_CXXFLAGS) $(OPTIMIZE_CXXFLAGS) $(CONFIG_CXXFLAGS) \
 	-fimplicit-templates
```

Then **regenerate** `src/c++23/Makefile.in` (do not hand-edit it) with the exact
autotools versions GCC pins — `automake 1.15.1` / `autoconf 2.69` — e.g. via
`contrib/config-list.mk`/`autoreconf` in that tree, otherwise the diff will be
full of spurious churn. The regenerated `Makefile.in` gets the same one-token
change in its copied `AM_CXXFLAGS`.

This mirrors `src/c++17/Makefile.am`, which already reads
`-std=gnu++17 -nostdinc++`, so it is a consistency fix, not a new idea.

## Commit message / ChangeLog (GCC format)

```
libstdc++: add -nostdinc++ when building the std module [PR100017]

The C++23 std/std.compat modules are compiled from src/c++23/std.cc with
AM_CXXFLAGS, but that variable lacked -nostdinc++, unlike src/c++17 (fixed in
PR100017).  In a Canadian cross the host libstdc++ <fenv.h> wrapper is then on
the include path; it shares the _GLIBCXX_FENV_H guard with the target wrapper,
so `#include_next <fenv.h>` never reaches the libc header, `::fenv_t` is
undeclared, std.cc fails to compile and an empty std module is shipped.

	PR libstdc++/100017
	PR libstdc++/101060

libstdc++-v3/ChangeLog:

	* src/c++23/Makefile.am (AM_CXXFLAGS): Add -nostdinc++, matching
	src/c++17.
	* src/c++23/Makefile.in: Regenerate.

Signed-off-by: Jonas Heinle <jonasheinle@googlemail.com>
```

## Submission steps

1. **Bugzilla**: comment on PR100017/PR101060 (or file a new PR) noting `src/c++23`
   never received the `-nostdinc++` fix, with a minimal Canadian-cross repro
   (`--build=x86_64-linux-gnu --host=aarch64-linux-gnu --target=aarch64-linux-gnu`,
   `--enable-languages=c,c++`) and the `fenv_t has not been declared` output.
2. **Legal**: GCC accepts the **DCO** (`Signed-off-by:`) for small contributions in
   lieu of FSF copyright assignment; a one-token flag change is well under the
   threshold. Keep the sign-off in the commit.
3. **Test**: bootstrap + a Canadian-cross build showing `std.cc` compiles clean and
   the installed `std.cc`/`std.gcm` are non-empty; ideally
   `make check-target-libstdc++-v3` for no regressions on a native build.
4. **Send**: `git format-patch -1` then `git send-email` to
   **gcc-patches@gcc.gnu.org**, CC the libstdc++ maintainers (see `MAINTAINERS`).
   Subject prefix `[PATCH] libstdc++:`.

## Relationship to our downstream fix

`build-gcc.sh` seds `-nostdinc++` into the shipped `Makefile.in` before configure.
Our guard `! grep -q -- '-nostdinc++'` makes it a **no-op the moment upstream lands
this**, so we can drop the downstream patch after bumping to a fixed GCC without
any coordination. See `linux/scripts/02-toolchain/build-gcc.sh` and memory
`canadian-cross-fenv-module-noise`.
