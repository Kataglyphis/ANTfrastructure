// The fake ABI rejects wrong copy arguments and missing cleanup; it proves no real GPU behavior.
#include <cstddef>
#include <cstdint>
#include <cstdlib>

namespace {
int selected = -1;
void *allocation{};
bool reset_called{};
struct CleanupVerdict
{
    ~CleanupVerdict()
    {
        if (allocation != nullptr || (selected >= 0 && !reset_called)) { std::_Exit(91); }
    }
} cleanup_verdict;
void process_exit_callback(int, void *)
{
    if (allocation != nullptr) { std::_Exit(96); }
}

}// namespace

extern "C" {
int hipInit(unsigned int) { return on_exit(process_exit_callback, nullptr); }
int hipSetDevice(int device)
{
    if (device < 0) { return 101; }
    selected = device;
    return 0;
}
int hipMalloc(void **pointer, std::size_t size)
{
    if (selected == 43) { return 2; }
    allocation = std::malloc(size);
    *pointer = allocation;
    return allocation == nullptr ? 2 : 0;
}
int hipMemcpy(void *destination, const void *source, std::size_t size, int kind)
{
    if (destination != allocation || source == nullptr || size != sizeof(std::uint32_t) || kind != 1
        || *static_cast<const std::uint32_t *>(source) != 0) {
        std::_Exit(92);
    }
    // Matching LSan's code without teardown must fail the report gate.
    if (selected == 47) { std::_Exit(86); }
    // A deliberate child leak proves the helper reaches sanitizer teardown before process exit.
    if (selected == 46) {
        void *volatile leaked = std::malloc(17);
        if (leaked == nullptr) { std::_Exit(94); }
    }
    return selected == 42 ? 3 : 0;
}
int hipFree(void *pointer)
{
    if (pointer != allocation) { std::_Exit(93); }
    std::free(pointer);
    allocation = nullptr;
    return selected == 44 ? 4 : 0;
}
int hipDeviceReset()
{
    reset_called = true;
    return selected == 45 ? 5 : 0;
}
}
