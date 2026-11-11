// This bounded SDK probe exercises real registration and inference, not a finished consumer package.
#include "ort_plugin_eps.hpp"
#include <onnxruntime_c_api.h>

#include <array>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace plugins = antfrastructure::ort_plugins;

template<typename T> using Owned = std::unique_ptr<T, void(ORT_API_CALL *)(T *)>;

void checked(const OrtApi &api, OrtStatus *status)
{
    if (status == nullptr) { return; }
    const std::string reason = api.GetErrorMessage(status);
    api.ReleaseStatus(status);
    throw std::runtime_error(reason);
}

void session_probe(const OrtApi &api,
  OrtEnv *env,
  plugins::PluginRegistry<OrtApi> &registry,
  const std::filesystem::path &model,
  const std::filesystem::path &prefix,
  bool gpu)
{
    OrtSessionOptions *raw_options = nullptr;
    checked(api, api.CreateSessionOptions(&raw_options));
    const Owned<OrtSessionOptions> options(raw_options, api.ReleaseSessionOptions);
    checked(api, api.EnableProfiling(options.get(), prefix.c_str()));
    checked(api, api.SetIntraOpNumThreads(options.get(), 2));
    if (gpu) {
        std::string reason;
        const plugins::PluginRegistry<OrtApi>::ProviderOptions values{ { "device_id", "0" } };
        if (!registry.append_provider(options.get(), plugins::migraphx, 0, {}, values, reason)) {
            throw std::runtime_error(reason);
        }
    } else if (!registry.registered_libraries().empty()) {
        throw std::runtime_error("CPU probe registered a plugin");
    }
    OrtSession *raw_session = nullptr;
    checked(api, api.CreateSession(env, model.c_str(), options.get(), &raw_session));
    const Owned<OrtSession> session(raw_session, api.ReleaseSession);
    OrtMemoryInfo *raw_memory = nullptr;
    checked(api, api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &raw_memory));
    const Owned<OrtMemoryInfo> memory(raw_memory, api.ReleaseMemoryInfo);
    std::array<float, 1> input{ -1.0F };
    const std::array<int64_t, 1> dimensions{ 1 };
    OrtValue *raw_input = nullptr;
    checked(api,
      api.CreateTensorWithDataAsOrtValue(memory.get(),
        input.data(),
        sizeof(input),
        dimensions.data(),
        dimensions.size(),
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &raw_input));
    const Owned<OrtValue> input_value(raw_input, api.ReleaseValue);
    const OrtValue *input_pointer = input_value.get();
    const char *input_name = "x";
    const char *output_name = "y";
    OrtValue *raw_output = nullptr;
    checked(api, api.Run(session.get(), nullptr, &input_name, &input_pointer, 1, &output_name, 1, &raw_output));
    const Owned<OrtValue> output(raw_output, api.ReleaseValue);
    void *data = nullptr;
    checked(api, api.GetTensorMutableData(output.get(), &data));
    if (data == nullptr || *static_cast<float *>(data) != 0.0F) { throw std::runtime_error("Wrong Relu output"); }
    OrtAllocator *allocator = nullptr;
    checked(api, api.GetAllocatorWithDefaultOptions(&allocator));
    char *profile = nullptr;
    checked(api, api.SessionEndProfiling(session.get(), allocator, &profile));
    std::cout << (gpu ? "MIGraphX" : "CPUExecutionProvider") << '\t' << profile << '\n';
    allocator->Free(allocator, profile);
}

int main(int argc, char **argv)
{
    std::cout << std::unitbuf;
    try {
        if (argc != 3) { throw std::runtime_error("Expected MODEL and OUTPUT_DIRECTORY"); }
        const auto *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
        if (api == nullptr) { throw std::runtime_error("Required ORT API is unavailable"); }
        OrtEnv *raw_env = nullptr;
        checked(*api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "native-plugin-probe", &raw_env));
        const Owned<OrtEnv> env(raw_env, api->ReleaseEnv);
        plugins::PluginRegistry<OrtApi> registry(*api, env.get());
        const std::filesystem::path directory(argv[2]);
        session_probe(*api, env.get(), registry, argv[1], directory / "cpu", false);
        for (int index = 0; index != 2; ++index) {
            session_probe(*api, env.get(), registry, argv[1], directory / ("migraphx-" + std::to_string(index)), true);
            if (registry.registered_libraries() != std::vector<std::string>{ "MIGraphX" }) {
                throw std::runtime_error("Wrong successful registration report");
            }
        }
        std::cout << "NATIVE-PLUGIN-RUNTIME PASS: CPU and two real V2 GPU sessions\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
