// Replay recorded inputs through an explicit native core; this is a diagnostic, not consumer or package acceptance.
#include "ort_probe_session.hpp"
#include "ort_tensor_io.hpp"
#include <dlfcn.h>
#include <iostream>

namespace probes = antfrastructure::ort_probes;
namespace tensors = antfrastructure::ort_tensors;
namespace plugins = antfrastructure::ort_plugins;
using probes::checked;

auto io_name(const OrtApi &api, OrtSession *session, bool input) -> std::string
{
    OrtAllocator *allocator = nullptr;
    checked(api, api.GetAllocatorWithDefaultOptions(&allocator));
    char *raw = nullptr;
    checked(api, input ? api.SessionGetInputName(session, 0, allocator, &raw) : api.SessionGetOutputName(session, 0, allocator, &raw));
    const auto release = [allocator](char *value) { allocator->Free(allocator, value); };
    const std::unique_ptr<char, decltype(release)> name(raw, release);
    if (!name || name.get()[0] == '\0') { throw std::runtime_error("Missing model tensor name"); }
    return name.get();
}

auto output_shape(const OrtApi &api, OrtValue *value) -> tensors::Shape
{
    const OrtMemoryInfo *memory = nullptr;
    checked(api, api.GetTensorMemoryInfo(value, &memory));
    OrtMemoryInfoDeviceType device{};
    api.MemoryInfoGetDeviceType(memory, &device);
    if (device != OrtMemoryInfoDeviceType_CPU) { throw std::runtime_error("Output is not CPU-accessible"); }
    OrtTensorTypeAndShapeInfo *raw = nullptr;
    checked(api, api.GetTensorTypeAndShape(value, &raw));
    const probes::Owned<OrtTensorTypeAndShapeInfo> info(raw, api.ReleaseTensorTypeAndShapeInfo);
    ONNXTensorElementDataType type{};
    checked(api, api.GetTensorElementType(info.get(), &type));
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { throw std::runtime_error("Output is not float32"); }
    size_t rank = 0, count = 0;
    checked(api, api.GetDimensionsCount(info.get(), &rank));
    if (rank == 0 || rank > 8) { throw std::runtime_error("Invalid output rank"); }
    tensors::Shape shape(rank);
    checked(api, api.GetDimensions(info.get(), shape.data(), shape.size()));
    checked(api, api.GetTensorShapeElementCount(info.get(), &count));
    if (tensors::elements(shape) != count) { throw std::runtime_error("Output count differs from shape"); }
    return shape;
}

void replay(const OrtApi &api, OrtEnv *environment, plugins::PluginRegistry<OrtApi> &registry,
  const std::filesystem::path &model, const tensors::Shape &shape, std::vector<float> &input,
  const std::filesystem::path &output, bool gpu)
{
    const auto options = probes::options(api, registry, output / "profile", gpu, 0);
    checked(api, api.AddSessionConfigEntry(options.get(), "session.intra_op.allow_spinning", "1"));
    const auto session = probes::session(api, environment, model, options.get());
    size_t inputs = 0, outputs = 0;
    checked(api, api.SessionGetInputCount(session.get(), &inputs));
    checked(api, api.SessionGetOutputCount(session.get(), &outputs));
    if (inputs != 1 || outputs == 0) { throw std::runtime_error("Replay requires one input and at least one output"); }
    const auto in = io_name(api, session.get(), true), out = io_name(api, session.get(), false);
    const char *in_name = in.c_str(), *out_name = out.c_str();
    const auto data = probes::cpu_input(api, input.data(), input.size(), shape.data(), shape.size());
    const OrtValue *pointer = data.tensor.get();
    for (unsigned run = 1; run <= 2; ++run) {
        OrtValue *raw = nullptr;
        checked(api, api.Run(session.get(), nullptr, &in_name, &pointer, 1, &out_name, 1, &raw));
        const probes::Owned<OrtValue> result(raw, api.ReleaseValue);
        const auto dimensions = output_shape(api, result.get());
        void *values = nullptr;
        checked(api, api.GetTensorMutableData(result.get(), &values));
        tensors::snapshot(output / "tensors", run, shape, input, dimensions, static_cast<float *>(values), tensors::elements(dimensions));
    }
    OrtAllocator *allocator = nullptr;
    checked(api, api.GetAllocatorWithDefaultOptions(&allocator));
    char *profile = nullptr;
    checked(api, api.SessionEndProfiling(session.get(), allocator, &profile));
    std::cout << "PROFILE\t" << profile << '\n';
    allocator->Free(allocator, profile);
}

int main(int argc, char **argv)
{
    std::cout << std::unitbuf;
    try {
        if (argc != 7) { throw std::runtime_error("Expected CORE MODEL SHAPE_CSV INPUT.f32le cpu|migraphx NEW_OUTPUT"); }
        const std::string selected(argv[5]);
        if (selected != "cpu" && selected != "migraphx") { throw std::runtime_error("Unknown replay device"); }
        const auto shape = tensors::parse_shape(argv[3]);
        auto input = tensors::read_input(argv[4], shape);
        const std::filesystem::path directory(argv[6]);
        if (!std::filesystem::create_directory(directory)) { throw std::runtime_error("Output already exists"); }
        std::filesystem::create_directory(directory / "tensors");
        const std::unique_ptr<void, decltype(&dlclose)> core(dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL), &dlclose);
        if (!core) { throw std::runtime_error(dlerror()); }
        using GetBase = const OrtApiBase *(ORT_API_CALL *)();
        const auto get_base = reinterpret_cast<GetBase>(dlsym(core.get(), "OrtGetApiBase"));
        if (get_base == nullptr) { throw std::runtime_error("Core lacks OrtGetApiBase"); }
        const auto *api = get_base()->GetApi(ORT_API_VERSION);
        if (api == nullptr) { throw std::runtime_error("Required SDK API is unavailable"); }
        const auto env = probes::environment(*api, "native-tensor-replay");
        plugins::PluginRegistry<OrtApi> registry(*api, env.get());
        std::string error;
        const auto owning = plugins::owning_library_directory(reinterpret_cast<const void *>(api->GetErrorMessage), error);
        if (!owning) { throw std::runtime_error(error); }
        std::cout << "CORE\t" << *owning << "\nVERSION\t" << get_base()->GetVersionString() << "\nDEVICE\t" << selected << '\n';
        replay(*api, env.get(), registry, argv[2], shape, input, directory, selected == "migraphx");
        if (registry.registered_libraries() != (selected == "migraphx" ? std::vector<std::string>{ "MIGraphX" } : std::vector<std::string>{})) {
            throw std::runtime_error("Unexpected successful registration roster");
        }
        std::cout << "TENSOR-REPLAY diagnostic complete; numerical/provider acceptance remains separate\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
