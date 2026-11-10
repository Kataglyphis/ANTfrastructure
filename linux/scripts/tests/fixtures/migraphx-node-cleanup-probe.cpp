// The minimal C ABI fixture checks callback adjustment and deletion, not a real SDK or GPU.
#include <array>
#include <cstdint>
#include <iostream>
#include <span>
#include <stdexcept>

struct OrtStatus {};
struct OrtNodeComputeContext {};
struct OrtKernelContext {};
enum OrtErrorCode { ORT_EP_FAIL };
struct OrtNodeComputeInfo
{
    std::uint32_t version{};
    OrtStatus *(*CreateState)(OrtNodeComputeInfo *, OrtNodeComputeContext *, void **) noexcept{};
    OrtStatus *(*Compute)(OrtNodeComputeInfo *, void *, OrtKernelContext *) noexcept{};
    void (*ReleaseState)(OrtNodeComputeInfo *, void *) noexcept{};
};

namespace Ort {
struct Exception : std::runtime_error { using std::runtime_error::runtime_error; };
struct Status
{
    bool failed{};
    Status() = default;
    explicit Status(const Exception &) : failed(true) {}
    Status(const char *, OrtErrorCode) : failed(true) {}
    auto release() const -> OrtStatus *
    {
        static OrtStatus error;
        return failed ? &error : nullptr;
    }
};
struct KernelContext { explicit KernelContext(OrtKernelContext *) {} };
}
namespace gsl { template<typename T> using span = std::span<T>; }
#define STATUS_OK Ort::Status{}
#define API_CALL_S(type, pointer, function, ...) return (reinterpret_cast<type *>(pointer)->function(__VA_ARGS__)).release()
#define API_CALL_V(type, pointer, function, ...) reinterpret_cast<type *>(pointer)->function(__VA_ARGS__)

namespace mgx_ep {
auto NegotiatedOrtApiVersion() -> std::uint32_t { return 31; }
struct ComputeState { int calls{}; };
struct EpContextComputeState { int calls{}; };
struct ExecutionProvider
{
    ComputeState ordinary;
    EpContextComputeState cached;
    Ort::Status ReleaseNodeComputeInfos(gsl::span<OrtNodeComputeInfo *>) noexcept;
};

#include "nodes.inc"

auto NodeComputeInfo::CreateState(OrtNodeComputeContext *, void *&state) noexcept -> Ort::Status
{ state = &ep_.ordinary; return STATUS_OK; }
auto NodeComputeInfo::Compute(ComputeState &state, const Ort::KernelContext &) noexcept -> Ort::Status
{ ++state.calls; return &state == &ep_.ordinary ? STATUS_OK : Ort::Status{"wrong state", ORT_EP_FAIL}; }
auto EpContextNodeComputeInfo::CreateState(OrtNodeComputeContext *, void *&state) noexcept -> Ort::Status
{ state = &ep_.cached; return STATUS_OK; }
auto EpContextNodeComputeInfo::Compute(EpContextComputeState &state, const Ort::KernelContext &) noexcept -> Ort::Status
{ ++state.calls; return &state == &ep_.cached ? STATUS_OK : Ort::Status{"wrong state", ORT_EP_FAIL}; }

#include "release.inc"
}

int main()
{
    mgx_ep::ExecutionProvider provider;
    std::array<OrtNodeComputeInfo *, 3> nodes{
        new mgx_ep::NodeComputeInfo(provider), nullptr, new mgx_ep::EpContextNodeComputeInfo(provider)
    };
    int checks = 0;
    const auto require = [&checks](bool ok) {
        if (!ok) { throw std::runtime_error("node cleanup assertion failed"); }
        ++checks;
    };
    OrtNodeComputeContext context;
    OrtKernelContext kernel;
    for (auto *node : nodes) {
        if (node == nullptr) { continue; }
        require(node->version == 31);
        void *state = nullptr;
        require(node->CreateState(node, &context, &state) == nullptr);
        require(state == (node == nodes[0] ? static_cast<void *>(&provider.ordinary) : &provider.cached));
        require(node->Compute(node, state, &kernel) == nullptr);
        node->ReleaseState(node, state);
    }
    require(provider.ordinary.calls == 1);
    require(provider.cached.calls == 1);
    require(provider.ReleaseNodeComputeInfos(nodes).release() == nullptr);
    std::cout << "MIGraphX node cleanup checks: " << checks << '\n';
}
