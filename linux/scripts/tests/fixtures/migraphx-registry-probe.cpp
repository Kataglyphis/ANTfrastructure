// A fake registry owner exposes source lifetime and creation races; real SDK and GPU checks remain separate.
#include <array>
#include <atomic>
#include <barrier>
#include <chrono>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <vector>

namespace {
std::atomic<int> attempts{}, created{}, released{}, transfers{}, fail_next{}, kernel_count{2};
int checks{};
void require(bool condition)
{
    if (!condition) { throw std::runtime_error("registry ownership assertion failed"); }
    ++checks;
}
}

struct OrtKernelRegistry { int marker{37}; };
namespace hip {
struct DataTransfer
{
    DataTransfer() { ++transfers; }
    ~DataTransfer() { --transfers; }
};
}
namespace Ort {
struct Status { int code{}; };
struct RegistryDeleter
{
    void operator()(OrtKernelRegistry *registry) const
    {
        if (transfers.load() == 0) { std::terminate(); }
        delete registry;
        ++released;
    }
};
struct KernelRegistry
{
    std::unique_ptr<OrtKernelRegistry, RegistryDeleter> value;
    explicit KernelRegistry(OrtKernelRegistry *registry) : value(registry) {}
    operator OrtKernelRegistry *() const { return value.get(); }
};
}
#define STATUS_OK Ort::Status{}
#define RETURN_IF_ERROR(expression) do { auto status = (expression); if (status.code != 0) { return status; } } while (false)

namespace mgx_ep {
auto GetNumRegisteredKernels() -> std::size_t { return static_cast<std::size_t>(kernel_count.load()); }
auto CreateKernelRegistry(std::string_view, void *state, OrtKernelRegistry *&registry) -> Ort::Status
{
    registry = nullptr;
    ++attempts;
    if (state == nullptr) { throw std::runtime_error("missing data transfer"); }
    if (fail_next.exchange(0) != 0) { return {42}; }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    registry = new OrtKernelRegistry;
    ++created;
    return STATUS_OK;
}
struct ProviderFactory
{
    ProviderFactory() : data_transfer_(std::make_unique<hip::DataTransfer>()) {}
    Ort::Status GetKernelRegistry(std::string_view, const OrtKernelRegistry *&) const;
private:
#include "registry-members.inc"
};
#include "registry-function.inc"
}

void check_empty_registry()
{
    kernel_count = 0;
    mgx_ep::ProviderFactory factory;
    const OrtKernelRegistry *registry = reinterpret_cast<OrtKernelRegistry *>(1);
    require(factory.GetKernelRegistry("MIGraphX", registry).code == 0);
    require(registry == nullptr);
    require(attempts.load() == 0);
    kernel_count = 2;
}

void check_retry_and_reuse()
{
    mgx_ep::ProviderFactory factory;
    fail_next = 1;
    const OrtKernelRegistry *registry = reinterpret_cast<OrtKernelRegistry *>(1);
    require(factory.GetKernelRegistry("MIGraphX", registry).code == 42);
    require(registry == nullptr);
    require(created.load() == 0);
    require(factory.GetKernelRegistry("MIGraphX", registry).code == 0);
    require(registry != nullptr);
    require(registry->marker == 37);
    const auto *first = registry;
    require(factory.GetKernelRegistry("MIGraphX", registry).code == 0);
    require(registry == first);
    require(attempts.load() == 2);
}

void check_parallel_creation()
{
    mgx_ep::ProviderFactory factory;
    std::array<const OrtKernelRegistry *, 12> registries{};
    std::array<int, 12> statuses{};
    std::barrier ready{12};
    std::vector<std::thread> workers;
    for (std::size_t index = 0; index < registries.size(); ++index) {
        workers.emplace_back([&, index] {
            ready.arrive_and_wait();
            statuses[index] = factory.GetKernelRegistry("MIGraphX", registries[index]).code;
        });
    }
    for (auto &worker : workers) { worker.join(); }
    for (std::size_t index = 0; index < registries.size(); ++index) {
        require(statuses[index] == 0);
        require(registries[index] == registries[0]);
    }
    require(created.load() == 2);
}

void raw_leak_control()
{
    mgx_ep::ProviderFactory factory;
    const OrtKernelRegistry *registry{};
    require(factory.GetKernelRegistry("MIGraphX", registry).code == 0);
    require(registry != nullptr);
    std::cout << "MIGraphX raw registry control completed" << std::endl;
}

int main(int argc, char **)
{
    if (argc > 1) { raw_leak_control(); return 0; }
    check_empty_registry();
    check_retry_and_reuse();
    require(created.load() == 1 && released.load() == 1);
    check_parallel_creation();
    require(released.load() == 2);
    require(transfers.load() == 0);
    require(created.load() == released.load());
    std::cout << "MIGraphX registry checks: " << checks << '\n';
}
