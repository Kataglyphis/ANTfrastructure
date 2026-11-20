// Exact float transport for diagnostics; recorded bytes do not establish inference or provider acceptance.
#ifndef ANT_ORT_TENSOR_IO_HPP
#define ANT_ORT_TENSOR_IO_HPP
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace antfrastructure::ort_tensors {
using Shape = std::vector<int64_t>;
inline auto open_exclusive(const std::filesystem::path &path) -> FILE *
{
    static constexpr char exclusive_mode[] = "wbx";
#ifdef _WIN32
    return ::_wfopen(path.c_str(), std::filesystem::path(exclusive_mode).c_str());
#else
    return std::fopen(path.c_str(), exclusive_mode);
#endif
}
inline auto elements(const Shape &shape) -> size_t
{
    if (shape.empty() || shape.size() > 8) { throw std::runtime_error("Invalid tensor rank"); }
    size_t count = 1;
    for (const auto dimension : shape) {
        if (dimension <= 0 || static_cast<uint64_t>(dimension) > (1024ULL * 1024 * 1024 / 4) / count) {
            throw std::runtime_error("Invalid or excessive tensor shape");
        }
        count *= static_cast<size_t>(dimension);
    }
    return count;
}

inline auto parse_shape(const std::string &text) -> Shape
{
    Shape shape;
    std::istringstream stream(text);
    std::string token;
    while (std::getline(stream, token, ',')) {
        if (token.empty() || !std::all_of(token.begin(), token.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            throw std::runtime_error("Shape dimensions must be decimal integers");
        }
        shape.push_back(std::stoll(token));
    }
    if (text.empty() || text.back() == ',') { throw std::runtime_error("Incomplete tensor shape"); }
    (void)elements(shape);
    return shape;
}

inline auto read_input(const std::filesystem::path &path, const Shape &shape) -> std::vector<float>
{
    static_assert(sizeof(float) == 4);
    const auto count = elements(shape);
    if (std::filesystem::is_symlink(path) || !std::filesystem::is_regular_file(path)
        || std::filesystem::file_size(path) != count * 4) {
        throw std::runtime_error("Input is not the exact regular float32 payload");
    }
    std::ifstream stream(path, std::ios::binary);
    stream.exceptions(std::ios::badbit | std::ios::failbit);
    std::vector<unsigned char> bytes(count * 4);
    stream.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    std::vector<float> values(count);
    for (size_t i = 0; i != count; ++i) {
        const uint32_t bits = uint32_t(bytes[i * 4]) | uint32_t(bytes[i * 4 + 1]) << 8U
          | uint32_t(bytes[i * 4 + 2]) << 16U | uint32_t(bytes[i * 4 + 3]) << 24U;
        std::memcpy(&values[i], &bits, 4);
        if (!std::isfinite(values[i])) { throw std::runtime_error("Input has nonfinite values"); }
    }
    return values;
}

class NewFile {
  public:
    explicit NewFile(const std::filesystem::path &path) : file_(open_exclusive(path), std::fclose)
    {
        if (!file_) { throw std::runtime_error("Cannot create new tensor evidence: " + path.string()); }
    }
    void write(const void *bytes, size_t count)
    {
        if (std::fwrite(bytes, 1, count, file_.get()) != count) { throw std::runtime_error("Tensor write failed"); }
    }
    void finish()
    {
        if (std::fflush(file_.get()) != 0) { throw std::runtime_error("Tensor flush failed"); }
        if (std::fclose(file_.release()) != 0) { throw std::runtime_error("Tensor close failed"); }
    }
  private:
    std::unique_ptr<FILE, int (*)(FILE *)> file_;
};

inline auto payload(const std::filesystem::path &directory, const std::string &name,
  const Shape &shape, const float *values, size_t count) -> std::string
{
    if (values == nullptr || elements(shape) != count) { throw std::runtime_error("Tensor shape/data mismatch"); }
    NewFile file(directory / name);
    for (size_t i = 0; i != count; ++i) {
        uint32_t bits = 0;
        std::memcpy(&bits, values + i, 4);
        const std::array<unsigned char, 4> bytes{ static_cast<unsigned char>(bits),
          static_cast<unsigned char>(bits >> 8U), static_cast<unsigned char>(bits >> 16U), static_cast<unsigned char>(bits >> 24U) };
        file.write(bytes.data(), bytes.size());
    }
    file.finish();
    std::ostringstream json;
    json << "{\"path\":\"" << name << "\",\"dtype\":\"float32\",\"byte_order\":\"little\",\"shape\":[";
    for (size_t i = 0; i != shape.size(); ++i) { json << (i == 0 ? "" : ",") << shape[i]; }
    json << "]}";
    return json.str();
}

inline void snapshot(const std::filesystem::path &directory, unsigned run, const Shape &input_shape,
  const std::vector<float> &input, const Shape &output_shape, const float *output, size_t count)
{
    const auto stem = "run-" + std::to_string(run);
    const auto a = payload(directory, stem + "-input.f32le", input_shape, input.data(), input.size());
    const auto b = payload(directory, stem + "-output.f32le", output_shape, output, count);
    const auto json = "{\"schema_version\":1,\"run\":" + std::to_string(run) + ",\"input\":" + a + ",\"output\":" + b + "}\n";
    NewFile metadata(directory / (stem + ".json"));
    metadata.write(json.data(), json.size());
    metadata.finish();
}
} // namespace antfrastructure::ort_tensors
#endif
