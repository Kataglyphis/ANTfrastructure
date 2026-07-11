#ifndef LITERTLM_WIN_DLFCN_SHIM_H
#define LITERTLM_WIN_DLFCN_SHIM_H
/* Minimal <dlfcn.h> for the clang++ windows-msvc build of LiteRT / LiteRT-LM: maps the POSIX
   dynamic-loader API onto Win32. Header-only so no extra object/library is required.
   NOMINMAX/NOGDI come from the global CXXFLAGS; we deliberately do NOT force
   WIN32_LEAN_AND_MEAN here so a TU that also needs the full <windows.h> is not starved. */
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif
#define RTLD_LAZY     0x0001
#define RTLD_NOW      0x0002
#define RTLD_LOCAL    0x0000
#define RTLD_GLOBAL   0x0100
#define RTLD_NODELETE 0x1000
#define RTLD_NOLOAD   0x0004
#define RTLD_DEEPBIND 0x0000
#define RTLD_DEFAULT  ((void*)0)
#define RTLD_NEXT     ((void*)-1)
static inline void* dlopen(const char* filename, int flag) {
    (void)flag;
    if (filename == 0) return (void*)GetModuleHandleA(0);
    return (void*)LoadLibraryA(filename);
}
static inline int dlclose(void* handle) {
    return FreeLibrary((HMODULE)handle) ? 0 : -1;
}
static inline void* dlsym(void* handle, const char* name) {
    return (void*)(uintptr_t)GetProcAddress((HMODULE)handle, name);
}
static inline char* dlerror(void) {
    static char buf[256];
    DWORD e = GetLastError();
    if (e == 0) return (char*)0;
    DWORD n = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, e, 0, buf, (DWORD)sizeof(buf), NULL);
    if (n == 0) snprintf(buf, sizeof(buf), "dlerror: Win32 error %lu", (unsigned long)e);
    return buf;
}
#ifdef __cplusplus
}
#endif
#endif
