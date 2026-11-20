// Normal process exit lets HIP and sanitizer teardown run after the bounded copy and its cleanup.
#if defined(__linux__) && !defined(__ANDROID__)
#include "hip_copy.hpp"

#include <charconv>
#include <cstring>
#include <system_error>

int main(int argc, char **argv)
{
    if (argc != 3) { return 2; }
    int device = 0;
    const auto *end = argv[2] + std::strlen(argv[2]);
    const auto parsed = std::from_chars(argv[2], end, device);
    if (parsed.ec != std::errc{} || parsed.ptr != end) { return 2; }
    return static_cast<int>(kataglyphis::inference::hip_probe::copy_to_device(argv[1], device));
}
#endif
