// Copyright (c) 2026 Kataglyphis
// SPDX-License-Identifier: MIT

// GitHub's Windows runners write no WER LocalDumps, so the process records its own crash; see cmake/README.md.
#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <dbghelp.h>

#include <cstdio>
#include <cstring>
#include <cwchar>

namespace {

using WriteDumpFn = BOOL(WINAPI *)(HANDLE,
  DWORD,
  HANDLE,
  MINIDUMP_TYPE,
  PMINIDUMP_EXCEPTION_INFORMATION,
  PMINIDUMP_USER_STREAM_INFORMATION,
  PMINIDUMP_CALLBACK_INFORMATION);

constexpr LONG kIdle = 0;
constexpr LONG kReporting = 1;
constexpr LONG kDone = 2;
constexpr int kMaxFrames = 64;

wchar_t g_dump_dir[MAX_PATH] = {};
WriteDumpFn g_write_dump = nullptr;
LPTOP_LEVEL_EXCEPTION_FILTER g_previous = nullptr;
volatile LONG g_state = kIdle;

void emit(const char *text)
{
  DWORD written = 0;
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), text, static_cast<DWORD>(std::strlen(text)), &written, nullptr);
}

// module+RVA is exact without symbols; the module's PDB names it offline.
void describe(DWORD64 address, char *out, size_t size)
{
  HMODULE module = nullptr;
  char path[MAX_PATH] = "?";
  const DWORD flags = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
  if (GetModuleHandleExA(flags, reinterpret_cast<LPCSTR>(address), &module) == FALSE) { module = nullptr; }
  if (module != nullptr && GetModuleFileNameA(module, path, MAX_PATH) == 0) { std::snprintf(path, sizeof path, "?"); }
  const char *slash = std::strrchr(path, '\\');
  const DWORD64 base = reinterpret_cast<DWORD64>(module);
  std::snprintf(out,
    size,
    "%s+0x%llx",
    slash != nullptr ? slash + 1 : path,
    static_cast<unsigned long long>(address - base));
}

const char *access_kind(ULONG_PTR kind)
{
  if (kind == 0) { return "read"; }
  if (kind == 1) { return "write"; }
  if (kind == 8) { return "execute"; }
  return "access";
}

void print_exception(const EXCEPTION_RECORD *record)
{
  char where[MAX_PATH + 32];
  char line[MAX_PATH + 96];
  describe(reinterpret_cast<DWORD64>(record->ExceptionAddress), where, sizeof where);
  std::snprintf(line,
    sizeof line,
    "kataglyphis-crash: exception 0x%08lX at %s on thread %lu\n",
    record->ExceptionCode,
    where,
    GetCurrentThreadId());
  emit(line);
  if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2) {
    std::snprintf(line,
      sizeof line,
      "kataglyphis-crash: %s of 0x%llx\n",
      access_kind(record->ExceptionInformation[0]),
      static_cast<unsigned long long>(record->ExceptionInformation[1]));
    emit(line);
  }
}

void write_dump(EXCEPTION_POINTERS *info)
{
  wchar_t exe[MAX_PATH] = L"process";
  wchar_t path[MAX_PATH] = {};
  char line[2 * MAX_PATH];
  if (GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) { std::swprintf(exe, MAX_PATH, L"process"); }
  const wchar_t *slash = std::wcsrchr(exe, L'\\');
  std::swprintf(
    path, MAX_PATH, L"%ls\\%ls.%lu.dmp", g_dump_dir, slash != nullptr ? slash + 1 : exe, GetCurrentProcessId());
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    std::snprintf(line, sizeof line, "kataglyphis-crash: cannot create %ls (error %lu)\n", path, GetLastError());
    emit(line);
    return;
  }
  MINIDUMP_EXCEPTION_INFORMATION exception{ GetCurrentThreadId(), info, FALSE };
  const auto type = static_cast<MINIDUMP_TYPE>(
    MiniDumpWithThreadInfo | MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithUnloadedModules);
  const BOOL written = g_write_dump(GetCurrentProcess(), GetCurrentProcessId(), file, type, &exception, nullptr, nullptr);
  const DWORD error = written != FALSE ? 0 : GetLastError();
  CloseHandle(file);
  if (written != FALSE) {
    std::snprintf(line, sizeof line, "kataglyphis-crash: minidump %ls\n", path);
  } else {
    std::snprintf(line, sizeof line, "kataglyphis-crash: MiniDumpWriteDump failed (0x%08lX) for %ls\n", error, path);
  }
  emit(line);
}

#if defined(_M_X64) || defined(_M_ARM64)
DWORD64 &program_counter(CONTEXT &context)
{
#if defined(_M_ARM64)
  return context.Pc;
#else
  return context.Rip;
#endif
}

// A leaf function has no unwind entry: its caller is still in LR on ARM64 and at [RSP] on x64.
bool unwind_leaf(CONTEXT &context)
{
#if defined(_M_ARM64)
  if (context.Pc == context.Lr) { return false; }
  context.Pc = context.Lr;
#else
  context.Rip = *reinterpret_cast<const DWORD64 *>(context.Rsp);
  context.Rsp += sizeof(DWORD64);
#endif
  return true;
}

// __try keeps a corrupt stack from turning the report into a second crash.
int walk_frames(CONTEXT context, DWORD64 *frames, int capacity)
{
  int count = 0;
  __try {
    while (count < capacity && program_counter(context) != 0) {
      const DWORD64 pc = program_counter(context);
      frames[count++] = pc;
      DWORD64 image_base = 0;
      PRUNTIME_FUNCTION entry = RtlLookupFunctionEntry(pc, &image_base, nullptr);
      if (entry == nullptr) {
        if (!unwind_leaf(context)) { break; }
        continue;
      }
      PVOID handler_data = nullptr;
      DWORD64 establisher = 0;
      RtlVirtualUnwind(0, image_base, pc, entry, &context, &handler_data, &establisher, nullptr);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return count;
}
#endif

void print_frames(const CONTEXT *context)
{
#if defined(_M_X64) || defined(_M_ARM64)
  DWORD64 frames[kMaxFrames] = {};
  char where[MAX_PATH + 32];
  char line[MAX_PATH + 64];
  const int count = walk_frames(*context, frames, kMaxFrames);
  for (int i = 0; i < count; ++i) {
    describe(frames[i], where, sizeof where);
    std::snprintf(line, sizeof line, "kataglyphis-crash:   #%02d %s\n", i, where);
    emit(line);
  }
#else
  (void)context;
#endif
}

LONG WINAPI on_unhandled_exception(EXCEPTION_POINTERS *info)
{
  if (InterlockedCompareExchange(&g_state, kReporting, kIdle) == kIdle) {
    print_exception(info->ExceptionRecord);
    write_dump(info);
    print_frames(info->ContextRecord);
    InterlockedExchange(&g_state, kDone);
  } else {
    // A second crashing thread would end the process before the first one's dump is complete.
    for (int waited = 0; waited < 600 && g_state == kReporting; ++waited) { Sleep(100); }
  }
  return g_previous != nullptr ? g_previous(info) : EXCEPTION_CONTINUE_SEARCH;
}

bool install()
{
  const DWORD length = GetEnvironmentVariableW(L"KATAGLYPHIS_CRASH_DUMP_DIR", g_dump_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) { return false; }
  // Loaded before any crash: the crashing thread may hold the loader lock.
  HMODULE dbghelp = LoadLibraryExW(L"dbghelp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  FARPROC proc = dbghelp != nullptr ? GetProcAddress(dbghelp, "MiniDumpWriteDump") : nullptr;
  if (proc == nullptr) {
    emit("kataglyphis-crash: no MiniDumpWriteDump in dbghelp.dll; crashes stay unrecorded\n");
    return false;
  }
  g_write_dump = reinterpret_cast<WriteDumpFn>(reinterpret_cast<void (*)()>(proc));
  CreateDirectoryW(g_dump_dir, nullptr);
  g_previous = SetUnhandledExceptionFilter(on_unhandled_exception);
  return true;
}

// A static initializer, so gtest_main and every other main stay untouched.
const bool g_installed = install();

}// namespace

#endif
