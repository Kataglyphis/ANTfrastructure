// SDK probe lifecycle shared by tiny inference and raw tensor replay; no package acceptance is implied.
#ifndef ANT_ORT_PROBE_SESSION_HPP
#define ANT_ORT_PROBE_SESSION_HPP
#include "ort_plugin_eps.hpp"
#include <onnxruntime_c_api.h>
#include <memory>
#include <stdexcept>
#include <string>

namespace antfrastructure::ort_probes {
template<typename T> using Owned = std::unique_ptr<T, void(ORT_API_CALL *)(T *)>;

inline void checked(const OrtApi &api, OrtStatus *status)
{
    if (status == nullptr) { return; }
    const std::string reason = api.GetErrorMessage(status);
    api.ReleaseStatus(status);
    throw std::runtime_error(reason);
}

inline auto environment(const OrtApi &api, const char *label) -> Owned<OrtEnv>
{
    OrtEnv *value = nullptr;
    checked(api, api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, label, &value));
    return { value, api.ReleaseEnv };
}

inline auto options(const OrtApi &api, ort_plugins::PluginRegistry<OrtApi> &registry,
  const std::filesystem::path &prefix, bool gpu, int threads) -> Owned<OrtSessionOptions>
{
    OrtSessionOptions *raw = nullptr;
    checked(api, api.CreateSessionOptions(&raw));
    Owned<OrtSessionOptions> value(raw, api.ReleaseSessionOptions);
    checked(api, api.EnableProfiling(value.get(), prefix.c_str()));
    checked(api, api.SetIntraOpNumThreads(value.get(), threads));
    if (gpu) {
        std::string reason;
        const ort_plugins::PluginRegistry<OrtApi>::ProviderOptions values{ { "device_id", "0" } };
        if (!registry.append_provider(value.get(), ort_plugins::migraphx, 0, {}, values, reason)) {
            throw std::runtime_error(reason);
        }
    } else if (!registry.registered_libraries().empty()) {
        throw std::runtime_error("CPU probe registered a plugin");
    }
    return value;
}

inline auto session(const OrtApi &api, OrtEnv *env, const std::filesystem::path &model,
  OrtSessionOptions *options) -> Owned<OrtSession>
{
    OrtSession *value = nullptr;
    checked(api, api.CreateSession(env, model.c_str(), options, &value));
    return { value, api.ReleaseSession };
}

struct CpuInput {
    Owned<OrtMemoryInfo> memory;
    Owned<OrtValue> tensor;
};

inline auto cpu_input(const OrtApi &api, float *data, size_t count, const int64_t *shape, size_t rank) -> CpuInput
{
    OrtMemoryInfo *raw_memory = nullptr;
    checked(api, api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &raw_memory));
    Owned<OrtMemoryInfo> memory(raw_memory, api.ReleaseMemoryInfo);
    OrtValue *raw = nullptr;
    checked(api, api.CreateTensorWithDataAsOrtValue(memory.get(), data, count * sizeof(float), shape, rank,
      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &raw));
    return { std::move(memory), Owned<OrtValue>(raw, api.ReleaseValue) };
}
} // namespace antfrastructure::ort_probes
#endif
