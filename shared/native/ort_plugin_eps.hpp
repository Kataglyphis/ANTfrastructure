// SPDX-License-Identifier: MIT
#ifndef ANT_INFRASTRUCTURE_ORT_PLUGIN_EPS_HPP
#define ANT_INFRASTRUCTURE_ORT_PLUGIN_EPS_HPP

#include <cstdlib>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

struct OrtEnv;
struct OrtEpDevice;
struct OrtSessionOptions;
struct OrtStatus;

namespace antfrastructure::ort_plugins {

struct PluginLibrary
{
    std::string_view name;
    std::string_view root_variable;
    std::string_view linux_filename;
    std::string_view windows_filename;
};

inline constexpr PluginLibrary migraphx{ "MIGraphX", "ORT_AMDGPU_EP_ROOT", "libmigraphx-ep.so", "migraphx-ep.dll" };

namespace detail {

    inline auto environment_path(std::string_view name) -> std::filesystem::path
    {
#ifdef _WIN32
        const std::wstring variable(name.begin(), name.end());
        const auto *value = ::_wgetenv(variable.c_str());
#else
        const std::string variable(name);
        const auto *value = std::getenv(variable.c_str());
#endif
        return value == nullptr ? std::filesystem::path{} : std::filesystem::path{ value };
    }

    inline auto canonical_module(const std::filesystem::path &candidate, bool advertised, std::string &error)
      -> std::optional<std::filesystem::path>
    {
        std::error_code status;
        const auto resolved = std::filesystem::canonical(candidate, status);
        if (status) {
            std::error_code link_status;
            const auto entry = std::filesystem::symlink_status(candidate, link_status);
            if (!advertised && status == std::errc::no_such_file_or_directory && !std::filesystem::is_symlink(entry)) {
                return std::nullopt;
            }
            error = "Cannot resolve plugin module " + candidate.string() + ": " + status.message();
            return std::nullopt;
        }
        if (!std::filesystem::is_regular_file(resolved, status) || status) {
            error = "Plugin module is not a regular file: " + resolved.string();
            return std::nullopt;
        }
        return resolved;
    }

}// namespace detail

inline auto plugin_library_path(const PluginLibrary &plugin,
  const std::filesystem::path &bundled_directory,
  std::string &error) -> std::optional<std::filesystem::path>
{
    error.clear();
    const auto root = detail::environment_path(plugin.root_variable);
    const bool advertised = !root.empty();
#ifdef _WIN32
    const auto filename = std::filesystem::path(plugin.windows_filename);
#else
    const auto filename = std::filesystem::path(plugin.linux_filename);
#endif
    if (!advertised) {
        if (bundled_directory.empty()) { return std::nullopt; }
        if (!bundled_directory.is_absolute()) {
            error = "Bundled ORT directory must be absolute: " + bundled_directory.string();
            return std::nullopt;
        }
        return detail::canonical_module(bundled_directory / filename, false, error);
    }
    if (!root.is_absolute()) {
        error = std::string(plugin.root_variable) + " must be an absolute directory: " + root.string();
        return std::nullopt;
    }
    std::error_code status;
    if (!std::filesystem::is_directory(root, status) || status) {
        error = std::string(plugin.root_variable) + " is not a directory: " + root.string();
        return std::nullopt;
    }
#ifdef _WIN32
    const auto candidate = root / filename;
#else
    const auto candidate = root / "lib" / filename;
#endif
    return detail::canonical_module(candidate, true, error);
}

// An address in the supplied API locates its owning core without loading another runtime.
inline auto owning_library_directory(const void *address, std::string &error) -> std::optional<std::filesystem::path>
{
    error.clear();
    if (address == nullptr) {
        error = "The owning ONNX Runtime API address is missing";
        return std::nullopt;
    }
    std::filesystem::path library;
#ifdef _WIN32
    HMODULE module = nullptr;
    if (!::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          reinterpret_cast<LPCWSTR>(address),
          &module)) {
        error = "Cannot locate the owning ONNX Runtime module";
        return std::nullopt;
    }
    std::vector<wchar_t> filename(32768);
    const auto length = ::GetModuleFileNameW(module, filename.data(), static_cast<DWORD>(filename.size()));
    if (length == 0 || length >= filename.size()) {
        error = "Cannot read the owning ONNX Runtime module path";
        return std::nullopt;
    }
    library = std::wstring(filename.data(), length);
#else
    Dl_info information{};
    if (::dladdr(address, &information) == 0 || information.dli_fname == nullptr) {
        error = "Cannot locate the owning ONNX Runtime module";
        return std::nullopt;
    }
    library = information.dli_fname;
#endif
    std::error_code status;
    const auto resolved = std::filesystem::canonical(library, status);
    if (status) {
        error = "Cannot resolve the owning ONNX Runtime module: " + status.message();
        return std::nullopt;
    }
    return resolved.parent_path();
}

template<typename Api>
inline auto plugin_library_path(const Api &api, const PluginLibrary &plugin, std::string &error)
  -> std::optional<std::filesystem::path>
{
    const auto advertised = plugin_library_path(plugin, {}, error);
    if (advertised || !error.empty()) { return advertised; }
    const auto directory = owning_library_directory(reinterpret_cast<const void *>(api.GetErrorMessage), error);
    if (!directory) { return std::nullopt; }
    return plugin_library_path(plugin, *directory, error);
}

// A registry must be shared by callers of one live environment; it never unregisters external factories.
template<typename Api> class PluginRegistry
{
  public:
    using ProviderOptions = std::vector<std::pair<std::string, std::string>>;

    PluginRegistry(const Api &api, OrtEnv *environment) : api_(api), environment_(environment) {}
    PluginRegistry(const PluginRegistry &) = delete;
    auto operator=(const PluginRegistry &) -> PluginRegistry & = delete;

    auto register_library(const PluginLibrary &plugin,
      const std::filesystem::path &bundled_directory,
      std::string &error) -> bool
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return ensure_registered(plugin, bundled_directory, error);
    }

    auto append_provider(OrtSessionOptions *options,
      const PluginLibrary &plugin,
      int device_index,
      const std::filesystem::path &bundled_directory,
      const ProviderOptions &provider_options,
      std::string &error) -> bool
    {
        error.clear();
        if (device_index < 0) {
            error = "GPU device index must be non-negative";
            return false;
        }
        if (options == nullptr || api_.GetEpDevices == nullptr || api_.EpDevice_EpName == nullptr
            || api_.SessionOptionsAppendExecutionProvider_V2 == nullptr) {
            error = "The owning ONNX Runtime cannot attach plugin devices";
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (!ensure_registered(plugin, bundled_directory, error)) { return false; }
        const auto *device = select_device(plugin.name, device_index, error);
        if (device == nullptr) { return false; }
        std::vector<const char *> keys;
        std::vector<const char *> values;
        for (const auto &option : provider_options) {
            keys.push_back(option.first.c_str());
            values.push_back(option.second.c_str());
        }
        return accept_status(api_.SessionOptionsAppendExecutionProvider_V2(
                               options, environment_, &device, 1, keys.data(), values.data(), keys.size()),
          error);
    }

    auto registered_libraries() const -> std::vector<std::string>
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::string> names;
        for (const auto &entry : registered_) { names.push_back(entry.first); }
        return names;
    }

  private:
    auto accept_status(OrtStatus *status, std::string &error) const -> bool
    {
        if (status == nullptr) { return true; }
        auto release = [this](OrtStatus *value) { api_.ReleaseStatus(value); };
        const std::unique_ptr<OrtStatus, decltype(release)> owned(status, release);
        const auto *message = api_.GetErrorMessage(status);
        error = message == nullptr ? "ONNX Runtime returned an error without a message" : message;
        return false;
    }

    auto ensure_registered(const PluginLibrary &plugin,
      const std::filesystem::path &bundled_directory,
      std::string &error) -> bool
    {
        error.clear();
        if (environment_ == nullptr || api_.RegisterExecutionProviderLibrary == nullptr
            || api_.GetErrorMessage == nullptr || api_.ReleaseStatus == nullptr) {
            error = "The owning ONNX Runtime cannot register plugin libraries";
            return false;
        }
        const auto path = bundled_directory.empty() ? plugin_library_path(api_, plugin, error)
                                                    : plugin_library_path(plugin, bundled_directory, error);
        if (!path) {
            if (error.empty()) { error = std::string(plugin.name) + " plugin is unavailable"; }
            return false;
        }
        const std::string name(plugin.name);
        const auto previous = registered_.find(name);
        if (previous != registered_.end()) {
            if (previous->second == *path) { return true; }
            error = name + " is already registered from " + previous->second.string() + ", refusing " + path->string();
            return false;
        }
        if (!accept_status(api_.RegisterExecutionProviderLibrary(environment_, name.c_str(), path->c_str()), error)) {
            return false;
        }
        registered_.emplace(name, *path);
        return true;
    }

    auto select_device(std::string_view name, int index, std::string &error) const -> const OrtEpDevice *
    {
        const OrtEpDevice *const *devices = nullptr;
        std::size_t count = 0;
        if (!accept_status(api_.GetEpDevices(environment_, &devices, &count), error)) { return nullptr; }
        if (count != 0 && devices == nullptr) {
            error = "ONNX Runtime returned a null plugin device list";
            return nullptr;
        }
        int matching = 0;
        const OrtEpDevice *selected = nullptr;
        for (std::size_t position = 0; position < count; ++position) {
            const auto *device = devices[position];
            const auto *ep_name = device == nullptr ? nullptr : api_.EpDevice_EpName(device);
            if (ep_name == nullptr) {
                error = "ONNX Runtime returned an invalid plugin device";
                return nullptr;
            }
            if (name == ep_name && matching++ == index) { selected = device; }
        }
        if (selected == nullptr) {
            error = std::string(name) + " device index " + std::to_string(index) + " is unavailable; found "
                    + std::to_string(matching);
        }
        return selected;
    }

    const Api &api_;
    OrtEnv *environment_;
    mutable std::mutex mutex_;
    std::map<std::string, std::filesystem::path> registered_;
};

}// namespace antfrastructure::ort_plugins
#endif
