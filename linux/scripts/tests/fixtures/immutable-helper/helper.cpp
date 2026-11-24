#include <dlfcn.h>
#include <iostream>
#include <string>

int immutable_support();

int main(int argc, char **argv)
{
    const std::string argument = argc > 1 ? argv[1] : "";
    if (argument == "--exit47") return 47;
    if (argument == "--external") {
        void *module = dlopen("libexternal_helper.so", RTLD_NOW);
        if (!module) return 31;
        auto value = reinterpret_cast<int (*)()>(dlsym(module, "external_helper"));
        if (!value || value() != 17) return 32;
        dlclose(module);
    }
    std::cout << "helper " << immutable_support() << ' ' << argument << '\n';
}
