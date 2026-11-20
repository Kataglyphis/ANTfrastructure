// This bounded SDK probe exercises real registration and inference, not a finished consumer package.
#include "ort_probe_session.hpp"

#include <array>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace plugins = antfrastructure::ort_plugins;

using antfrastructure::ort_probes::Owned;
using antfrastructure::ort_probes::checked;
namespace probes = antfrastructure::ort_probes;

void session_probe(const OrtApi &api,
  OrtEnv *env,
  plugins::PluginRegistry<OrtApi> &registry,
  const std::filesystem::path &model,
  const std::filesystem::path &prefix,
  bool gpu)
{
    const auto options = probes::options(api, registry, prefix, gpu, 2);
    const auto session = probes::session(api, env, model, options.get());
    std::array<float, 1> input{ -1.0F };
    const std::array<int64_t, 1> dimensions{ 1 };
    const auto input_value = probes::cpu_input(api, input.data(), input.size(), dimensions.data(), dimensions.size());
    const OrtValue *input_pointer = input_value.tensor.get();
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
        const auto env = probes::environment(*api, "native-plugin-probe");
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
