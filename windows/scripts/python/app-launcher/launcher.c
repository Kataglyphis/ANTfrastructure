// One per entry point (New-PythonAppLauncher): runs <dir>\runtime\python.exe on it; arguments, Ctrl+C and exit code pass through.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#ifndef ENTRY_MODULE
#error "define ENTRY_MODULE, e.g. /DENTRY_MODULE=L\"orchestrant.yolo.monitor\""
#endif
#ifndef ENTRY_FUNC
#error "define ENTRY_FUNC, e.g. /DENTRY_FUNC=L\"run_yolo_monitor\""
#endif
#ifndef RUNTIME_EXE
#define RUNTIME_EXE L"runtime\\python.exe"
#endif

// Windows' own rule for the program name: a quoted run, else everything up to the first blank.
static const wchar_t *skip_program_name(const wchar_t *cmd) {
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd == L'"') cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int wmain(void) {
    wchar_t self[32768];
    DWORD n = GetModuleFileNameW(NULL, self, (DWORD)(sizeof self / sizeof self[0]));
    if (n == 0 || n >= sizeof self / sizeof self[0]) {
        fwprintf(stderr, L"launcher: cannot read its own path (error %lu)\n", GetLastError());
        return 120;
    }
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 121;
    *slash = L'\0';
    const wchar_t *name = slash + 1;
    wchar_t prog[512];
    swprintf(prog, 512, L"%ls", name);
    wchar_t *dot = wcsrchr(prog, L'.');
    if (dot) *dot = L'\0';

    size_t cap = wcslen(self) + 64;
    wchar_t *python = malloc(cap * sizeof(wchar_t));
    if (!python) return 124;
    swprintf(python, cap, L"%ls\\%ls", self, RUNTIME_EXE);
    if (GetFileAttributesW(python) == INVALID_FILE_ATTRIBUTES) {
        fwprintf(stderr, L"launcher: %ls not found; the bundle is incomplete\n", python);
        return 122;
    }

#ifdef DATA_ENV
    {
        size_t dcap = wcslen(self) + 128;
        wchar_t *data = malloc(dcap * sizeof(wchar_t));
        if (!data) return 124;
        swprintf(data, dcap, L"%ls\\%ls", self, DATA_SUBDIR);
        SetEnvironmentVariableW(DATA_ENV, data);
        free(data);
    }
#endif

    // -I keeps PYTHON* variables and the user site out; sys.argv[0] gets the launcher's name back for --help.
    const wchar_t *args = skip_program_name(GetCommandLineW());
    size_t len = wcslen(python) + wcslen(args) + wcslen(prog) + 512;
    wchar_t *cmd = malloc(len * sizeof(wchar_t));
    if (!cmd) return 124;
    swprintf(cmd, len,
             L"\"%ls\" -I -c \"import sys; sys.argv[0] = '%ls'; from %ls import %ls as _entry; sys.exit(_entry())\" %ls",
             python, prog, ENTRY_MODULE, ENTRY_FUNC, args);

    // A job that dies with the launcher, so a killed launcher never leaves Python running.
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
        ZeroMemory(&info, sizeof info);
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof info);
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    if (!CreateProcessW(python, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"launcher: cannot start %ls (error %lu)\n", python, GetLastError());
        return 123;
    }
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);

    // Ctrl+C reaches Python through the shared console; the launcher only waits for it.
    SetConsoleCtrlHandler(NULL, TRUE);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    free(cmd);
    free(python);
    return (int)code;
}
