// [LiteRTLM-winfix rust-syslibs] force-link rust-std's windows-msvc system libs via /DEFAULTLIB
// directives baked into this .obj (the CMake link-flag routes silently dropped them). Same mechanism
// clang uses for msvcrt via --dependent-lib.
#if defined(_WIN32)
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "dbghelp.lib")
// CRT compat: oldnames maps POSIX names (cprintf/timezone/tzname/sys_errlist -> _cprintf/_timezone
// /...); legacy_stdio_definitions supplies the deprecated global data (_timezone/_tzname/_sys_errlist)
// that the split UCRT no longer auto-provides under --dependent-lib=msvcrt alone.
#pragma comment(lib, "oldnames.lib")
#pragma comment(lib, "legacy_stdio_definitions.lib")
// Complete the dynamic-CRT set: --dependent-lib=msvcrt pulls only the VCRuntime forwarder; the
// deprecated UCRT global data (_timezone/_daylight/_tzname/_environ/_sys_errlist/_sys_nerr, pulled in
// by rust-std/C deps) lives in ucrt.lib + vcruntime.lib, which /MD would normally auto-link.
#pragma comment(lib, "ucrt.lib")
#pragma comment(lib, "vcruntime.lib")
#endif

