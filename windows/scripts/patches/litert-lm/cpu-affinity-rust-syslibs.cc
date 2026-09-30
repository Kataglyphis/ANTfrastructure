// [LiteRTLM-winfix rust-syslibs] rust-std's system libs as /DEFAULTLIB: the CMake link-flag routes dropped them.
#if defined(_WIN32)
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "dbghelp.lib")
// oldnames maps POSIX CRT names; legacy_stdio_definitions has the deprecated globals the split UCRT dropped.
#pragma comment(lib, "oldnames.lib")
#pragma comment(lib, "legacy_stdio_definitions.lib")
// --dependent-lib=msvcrt pulls only the VCRuntime forwarder; the rest of the /MD set must be named.
#pragma comment(lib, "ucrt.lib")
#pragma comment(lib, "vcruntime.lib")
#endif

