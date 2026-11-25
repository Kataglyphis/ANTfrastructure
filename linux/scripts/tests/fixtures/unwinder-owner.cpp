// Prints which object owns _Unwind_RaiseException and whether LD_PRELOAD reached this process.
#include <dlfcn.h>

#include <cstdlib>
#include <filesystem>
#include <iostream>

int main() {
  Dl_info info{};
  dladdr(dlsym(RTLD_DEFAULT, "_Unwind_RaiseException"), &info);
  const char *preload = std::getenv("LD_PRELOAD");
  std::cout << std::filesystem::path(info.dli_fname).filename().string() << ' '
            << (preload ? "preload-exported" : "preload-unset") << '\n';
}
