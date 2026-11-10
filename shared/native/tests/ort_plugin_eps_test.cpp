// SPDX-License-Identifier: MIT
// Fake API callbacks prove policy and raw status cleanup, not native ABI compatibility or inference.
#include "ort_plugin_eps.hpp"
#include <atomic>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace fs = std::filesystem;
namespace plugins = antfrastructure::ort_plugins;

struct OrtStatus
{ std::string message; };
struct OrtEpDevice
{
    const char *name;
    int ordinal;
};
struct OrtEnv
{
    std::atomic<int> calls{ 0 };
    mutable std::atomic<int> enumerations{ 0 };
    bool fail_registration{ false };
    bool fail_enumeration{ false };
    bool null_list{ false };
    std::mutex records_mutex;
    std::string name;
    fs::path library;
    std::vector<const OrtEpDevice *> devices;
};
struct OrtSessionOptions
{
    bool fail_append{ false };
    int calls{ 0 };
    OrtEnv *environment{ nullptr };
    const OrtEpDevice *device{ nullptr };
    std::map<std::string, std::string> values;
};

namespace {
std::atomic<int> released{ 0 };
int checks = 0;

void check(bool condition, const char *name)
{
    ++checks;
    if (!condition) { throw std::runtime_error(std::string("CHECK failed: ") + name); }
}

auto register_library(OrtEnv *env, const char *name, const fs::path::value_type *path) -> OrtStatus *
{
    ++env->calls;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    const std::lock_guard<std::mutex> lock(env->records_mutex);
    env->name = name;
    env->library = path;
    return env->fail_registration ? new OrtStatus{ "native registration failed" } : nullptr;
}

auto get_devices(const OrtEnv *env, const OrtEpDevice *const **devices, std::size_t *count) -> OrtStatus *
{
    ++env->enumerations;
    if (env->fail_enumeration) { return new OrtStatus{ "native enumeration failed" }; }
    *count = env->devices.size();
    *devices = env->null_list ? nullptr : env->devices.data();
    return nullptr;
}

auto append(OrtSessionOptions *options,
  OrtEnv *env,
  const OrtEpDevice *const *devices,
  std::size_t count,
  const char *const *keys,
  const char *const *values,
  std::size_t option_count) -> OrtStatus *
{
    ++options->calls;
    if (options->fail_append) { return new OrtStatus{ "native append failed" }; }
    if (count != 1 || devices == nullptr) { return new OrtStatus{ "invalid device array" }; }
    options->environment = env;
    options->device = devices[0];
    for (std::size_t index = 0; index < option_count; ++index) { options->values[keys[index]] = values[index]; }
    return nullptr;
}

struct Api
{
    OrtStatus *(
      *RegisterExecutionProviderLibrary)(OrtEnv *, const char *, const fs::path::value_type *) = register_library;
    OrtStatus *(*GetEpDevices)(const OrtEnv *, const OrtEpDevice *const **, std::size_t *) = get_devices;
    const char *(*EpDevice_EpName)(const OrtEpDevice *) = [](const OrtEpDevice *device) { return device->name; };
    OrtStatus *(*SessionOptionsAppendExecutionProvider_V2)(OrtSessionOptions *,
      OrtEnv *,
      const OrtEpDevice *const *,
      std::size_t,
      const char *const *,
      const char *const *,
      std::size_t) = append;
    const char *(*GetErrorMessage)(const OrtStatus *) = [](const OrtStatus *status) { return status->message.c_str(); };
    void (*ReleaseStatus)(OrtStatus *) = [](OrtStatus *status) {
        ++released;
        delete status;
    };
};

void set_root(const fs::path &value)
{
#ifdef _WIN32
    ::_wputenv_s(L"ORT_AMDGPU_EP_ROOT", value.c_str());
#else
    if (::setenv("ORT_AMDGPU_EP_ROOT", value.c_str(), 1) != 0) { throw std::runtime_error("setenv failed"); }
#endif
}

auto filename() -> fs::path
{
#ifdef _WIN32
    return fs::path(plugins::migraphx.windows_filename);
#else
    return fs::path(plugins::migraphx.linux_filename);
#endif
}

auto image_module(const fs::path &root) -> fs::path
{
#ifdef _WIN32
    return root / filename();
#else
    return root / "lib" / filename();
#endif
}

void write_module(const fs::path &path)
{
    fs::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary);
    output << "fixture";
    if (!output) { throw std::runtime_error("fixture write failed"); }
}

void path_policy(const fs::path &root)
{
    std::string error = "stale";
    set_root({});
    check(!plugins::plugin_library_path(plugins::migraphx, {}, error), "unadvertised module absent");
    check(error.empty(), "optional absence has no error");
    const auto bundle = root / "bundle with spaces";
    write_module(bundle / filename());
    check(plugins::plugin_library_path(plugins::migraphx, bundle, error) == fs::canonical(bundle / filename()),
      "bundled fallback");
    set_root("relative root");
    check(!plugins::plugin_library_path(plugins::migraphx, bundle, error), "relative root refused");
    check(error.find("absolute") != std::string::npos, "relative diagnostic");
    set_root(root / "absent image");
    check(!plugins::plugin_library_path(plugins::migraphx, bundle, error), "advertisement never falls back");
    check(!error.empty(), "missing root diagnostic");
    set_root(bundle / filename());
    check(!plugins::plugin_library_path(plugins::migraphx, bundle, error), "root must be directory");
    check(error.find("not a directory") != std::string::npos, "root file diagnostic");
    const auto image = root / "image with spaces";
    write_module(image_module(image));
    set_root(image);
    check(plugins::plugin_library_path(plugins::migraphx, bundle, error) == fs::canonical(image_module(image)),
      "image root precedence");
    fs::remove(image_module(image));
    fs::create_directory(image_module(image));
    check(!plugins::plugin_library_path(plugins::migraphx, bundle, error), "module directory refused");
    check(error.find("regular file") != std::string::npos, "module type diagnostic");
    fs::remove(image_module(image));
    check(!plugins::plugin_library_path(plugins::migraphx, bundle, error), "missing advertised module refused");
    check(!error.empty(), "module absence cannot hide behind fallback");
    set_root({});
    check(!plugins::plugin_library_path(plugins::migraphx, "relative bundle", error), "relative bundle refused");
    check(!error.empty(), "relative bundle diagnostic");
    fs::create_symlink(root / "absent target", root / filename());
    check(!plugins::plugin_library_path(plugins::migraphx, root, error), "broken bundled link refused");
    check(!error.empty(), "broken link is not optional absence");
}

void registrations(const fs::path &bundle)
{
    Api api;
    OrtEnv first, second;
    plugins::PluginRegistry<Api> a(api, &first), b(api, &second);
    std::string error;
    check(a.register_library(plugins::migraphx, bundle, error), "first registration");
    check(a.register_library(plugins::migraphx, bundle, error), "cached registration");
    check(first.calls == 1, "exactly one native call");
    check(first.name == "MIGraphX", "chosen library name");
    check(first.library == fs::canonical(bundle / filename()), "native canonical path");
    check(b.register_library(plugins::migraphx, bundle, error), "separate environment registration");
    check(second.calls == 1, "environment caches are independent");
    check(a.registered_libraries() == std::vector<std::string>{ "MIGraphX" }, "report successful registration");
    const auto alternate = bundle.parent_path() / "alternate image";
    write_module(image_module(alternate));
    set_root(alternate);
    check(!a.register_library(plugins::migraphx, bundle, error), "same name rejects different path");
    check(error.find("refusing") != std::string::npos && first.calls == 1, "conflict never calls native");
    set_root({});
    OrtEnv failing;
    failing.fail_registration = true;
    plugins::PluginRegistry<Api> retry(api, &failing);
    const auto released_before = released.load();
    check(!retry.register_library(plugins::migraphx, bundle, error), "native failure returned");
    check(error == "native registration failed", "native error retained");
    check(released == released_before + 1, "native status released");
    check(retry.registered_libraries().empty(), "failure not reported registered");
    failing.fail_registration = false;
    check(retry.register_library(plugins::migraphx, bundle, error), "failed call retry");
    check(failing.calls == 2 && error.empty(), "failure not cached");
}

void device_policy(const fs::path &bundle)
{
    Api api;
    OrtEpDevice cpu{ "CPUExecutionProvider", 0 }, first{ "MIGraphX", 7 }, legacy{ "MIGraphXExecutionProvider", 8 },
      second{ "MIGraphX", 9 };
    OrtEnv env;
    env.devices = { &cpu, &first, &legacy, &second };
    plugins::PluginRegistry<Api> registry(api, &env);
    OrtSessionOptions options;
    std::string error;
    check(!registry.append_provider(&options, plugins::migraphx, -1, bundle, {}, error), "negative index refused");
    check(env.calls == 0 && env.enumerations == 0, "negative before native calls");
    check(registry.append_provider(
            &options, plugins::migraphx, 1, bundle, { { "device_id", "1" }, { "migraphx_mem_limit", "42" } }, error),
      "append selected plugin");
    check(options.device == &second && options.environment == &env, "selected matching device and owning env");
    check(options.values.at("device_id") == "1" && options.values.at("migraphx_mem_limit") == "42", "options retained");
    check(env.calls == 1 && env.enumerations == 1, "one register one enumeration");
    check(
      registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "repeat uses first matching device");
    check(options.device == &first && env.calls == 1 && env.enumerations == 2, "fresh enumeration cached registration");
    env.devices = { &cpu, &legacy };
    check(!registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "legacy device never selected");
    check(error.find("found 0") != std::string::npos, "matching device diagnostic");
    env.devices = { &first };
    check(!registry.append_provider(&options, plugins::migraphx, 1, bundle, {}, error), "past-end index refused");
    env.fail_enumeration = true;
    check(!registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "enumeration status failure");
    check(error == "native enumeration failed", "enumeration error retained");
    env.fail_enumeration = false;
    options.fail_append = true;
    check(!registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "append status failure");
    check(error == "native append failed", "append error retained");
    options.fail_append = false;
    env.null_list = true;
    check(!registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "null list refused");
    env.null_list = false;
    env.devices = { nullptr };
    check(!registry.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "null device refused");
}

void unavailable_api(const fs::path &bundle)
{
    Api api;
    OrtEnv env;
    std::string error;
    plugins::PluginRegistry<Api> null_env(api, nullptr);
    check(!null_env.register_library(plugins::migraphx, bundle, error), "null environment refused");
    for (int scenario = 0; scenario < 6; ++scenario) {
        Api unavailable;
        if (scenario == 0) { unavailable.RegisterExecutionProviderLibrary = nullptr; }
        if (scenario == 1) { unavailable.GetErrorMessage = nullptr; }
        if (scenario == 2) { unavailable.ReleaseStatus = nullptr; }
        if (scenario == 3) { unavailable.GetEpDevices = nullptr; }
        if (scenario == 4) { unavailable.EpDevice_EpName = nullptr; }
        if (scenario == 5) { unavailable.SessionOptionsAppendExecutionProvider_V2 = nullptr; }
        plugins::PluginRegistry<Api> missing(unavailable, &env);
        OrtSessionOptions options;
        check(
          !missing.append_provider(&options, plugins::migraphx, 0, bundle, {}, error), "missing native API refused");
        check(!error.empty(), "missing native API diagnosed");
        check(env.calls == 0, "missing attachment API fails before registration");
    }
}

void owning_core_fallback(const fs::path &executable)
{
    Api api;
    std::string error;
    check(!plugins::owning_library_directory(nullptr, error), "missing owner address refused");
    check(!error.empty(), "missing owner diagnosed");
    const auto directory =
      plugins::owning_library_directory(reinterpret_cast<const void *>(api.GetErrorMessage), error);
    check(directory == fs::canonical(executable).parent_path(), "actual callback owner directory");
    write_module(*directory / filename());
    set_root({});
    check(plugins::plugin_library_path(api, plugins::migraphx, error) == fs::canonical(*directory / filename()),
      "fallback beside owning core");
    OrtEnv env;
    plugins::PluginRegistry<Api> registry(api, &env);
    check(registry.register_library(plugins::migraphx, {}, error), "default registration uses owning core");
    check(env.library == fs::canonical(*directory / filename()), "default native module identity");
}

void concurrent_registration(const fs::path &bundle)
{
    Api api;
    OrtEnv env;
    plugins::PluginRegistry<Api> registry(api, &env);
    std::atomic<int> ready{ 0 }, successes{ 0 };
    std::vector<std::thread> workers;
    for (int index = 0; index < 8; ++index) {
        workers.emplace_back([&] {
            ++ready;
            while (ready != 8) { std::this_thread::yield(); }
            std::string error;
            if (registry.register_library(plugins::migraphx, bundle, error)) { ++successes; }
        });
    }
    for (auto &worker : workers) { worker.join(); }
    check(successes == 8 && env.calls == 1, "shared lock guards all first callers");
}
}// namespace

int main(int argc, char **argv)
{
    try {
        check(argc >= 2, "fixture directory supplied");
        if (argc >= 3 && std::string(argv[2]) == "--fail-control") { check(false, "negative control"); }
        const auto root = fs::path(argv[1]);
        path_policy(root);
        const auto bundle = root / "bundle with spaces";
        registrations(bundle);
        device_policy(bundle);
        unavailable_api(bundle);
        concurrent_registration(bundle);
        owning_core_fallback(fs::path(argv[0]));
        std::cout << "native plugin policy checks: " << checks << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
