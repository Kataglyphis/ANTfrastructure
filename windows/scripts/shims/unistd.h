#ifndef LITERTLM_WIN_UNISTD_SHIM_H
#define LITERTLM_WIN_UNISTD_SHIM_H
/* POSIX <unistd.h> bits for LiteRT's clang++ build; setenv exists because dynamic_loading.cc edits LD_LIBRARY_PATH. */
#include <io.h>
#include <process.h>
#include <direct.h>
#include <stdlib.h>
#include <string.h>
#ifndef R_OK
#define R_OK 4
#endif
#ifndef W_OK
#define W_OK 2
#endif
#ifndef X_OK
#define X_OK 0
#endif
#ifndef F_OK
#define F_OK 0
#endif
#ifdef __cplusplus
static inline int setenv(const char* name, const char* value, int overwrite) {
    if (!overwrite) {
        size_t sz = 0;
        if (getenv_s(&sz, 0, 0, name) == 0 && sz != 0) return 0;
    }
    return _putenv_s(name, value ? value : "");
}
static inline int unsetenv(const char* name) { return _putenv_s(name, ""); }
#endif
#endif
