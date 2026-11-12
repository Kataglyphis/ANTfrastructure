// Independent bytes and refusal controls cover transport, not an ONNX core or physical GPU.
#include "ort_tensor_io.hpp"
#include <functional>
#include <iostream>
#include <limits>

namespace tensors = antfrastructure::ort_tensors;
namespace fs = std::filesystem;
unsigned checks = 0;

void require(bool condition)
{
    ++checks;
    if (!condition) { throw std::runtime_error("Tensor IO assertion failed"); }
}
void refuses(const std::function<void()> &action)
{
    bool failed = false;
    try { action(); } catch (const std::exception &) { failed = true; }
    require(failed);
}
auto bytes(const fs::path &path) -> std::string
{
    std::ifstream input(path, std::ios::binary);
    return { std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>() };
}
void raw_fixture(const fs::path &path, const std::string &raw)
{
    std::ofstream output(path, std::ios::binary);
    output.write(raw.data(), static_cast<std::streamsize>(raw.size()));
    if (!output) { throw std::runtime_error("Independent fixture write failed"); }
}
void shape_controls()
{
    require(tensors::parse_shape("1,3,1,1") == tensors::Shape({ 1, 3, 1, 1 }));
    refuses([] { (void)tensors::elements({}); });
    for (const auto *shape : { "", "0", "-1", "+1", " 1", "1,,3", "1,", "1x", "1.0", "99999999999999999999999", "268435457", "1,1,1,1,1,1,1,1,1" }) {
        refuses([shape] { (void)tensors::parse_shape(shape); });
    }
}
void input_controls(const fs::path &root, const fs::path &input, const tensors::Shape &shape)
{
    const std::string raw("\315\314\214\077\0\0\0\200\0\0\0\100", 12);
    raw_fixture(input, raw);
    const auto data = tensors::read_input(input, shape);
    require(data.size() == 3 && data[0] == 1.1F && data[1] == 0.0F && std::signbit(data[1]) && data[2] == 2.0F);
    refuses([&] { (void)tensors::read_input(input, { 2 }); });
    fs::create_symlink(input, root / "linked");
    refuses([&] { (void)tensors::read_input(root / "linked", shape); });
    raw_fixture(root / "nan", std::string("\0\0\300\177", 4));
    refuses([&] { (void)tensors::read_input(root / "nan", { 1 }); });
    const auto emitted = tensors::payload(root, "roundtrip", shape, data.data(), data.size());
    require(bytes(root / "roundtrip") == raw);
    require(emitted.find("\"byte_order\":\"little\"") != std::string::npos);
}
void output_controls(const fs::path &root, const std::vector<float> &data, const tensors::Shape &shape)
{
    for (const auto *kind : { "cpu", "gpu" }) {
        fs::create_directory(root / kind);
        for (unsigned run = 1; run <= 2; ++run) { tensors::snapshot(root / kind, run, shape, data, { 3 }, data.data(), data.size()); }
    }
    require(bytes(root / "cpu/run-1-input.f32le") == bytes(root / "gpu/run-2-output.f32le"));
    raw_fixture(root / "keep", "preserve");
    refuses([&] { (void)tensors::payload(root, "keep", shape, data.data(), data.size()); });
    require(bytes(root / "keep") == "preserve");
    refuses([&] { (void)tensors::payload(root, "wrong-count", shape, data.data(), 2); });
    require(!fs::exists(root / "wrong-count"));
    refuses([&] { (void)tensors::payload(root / "missing", "child", shape, data.data(), data.size()); });
}
int main(int argc, char **argv)
{
    try {
        if (argc != 2 && argc != 3) { throw std::runtime_error("Expected a new fixture directory"); }
        if (argc == 3) {
            if (std::string(argv[2]) != "--fail-control") { throw std::runtime_error("Unknown fixture control"); }
            require(false);
        }
        const fs::path root(argv[1]);
        if (!fs::create_directory(root)) { throw std::runtime_error("Fixture already exists"); }
        shape_controls();
        const tensors::Shape shape{ 1, 3, 1, 1 };
        input_controls(root, root / "input", shape);
        const auto data = tensors::read_input(root / "input", shape);
        output_controls(root, data, shape);
        std::cout << "TENSOR-IO PASS: " << checks << " checks\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
