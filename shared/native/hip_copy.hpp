#pragma once

// Only the fresh helper loads HIP, so the caller's already initialized GPU state cannot reach this code.
#if defined(__linux__) && !defined(__ANDROID__)
#include <dlfcn.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>

namespace kataglyphis::inference::hip_probe {

enum class CopyStatus : int {
    Ok = EXIT_SUCCESS,
    MissingLibrary = 10,
    MissingSymbols,
    InitFailed,
    DeviceFailed,
    AllocationFailed,
    CopyFailed,
    FreeFailed,
    ResetFailed
};

struct HipApi
{
    using Init = int (*)(unsigned int);
    using SetDevice = int (*)(int);
    using Malloc = int (*)(void **, std::size_t);
    using Memcpy = int (*)(void *, const void *, std::size_t, int);
    using Free = int (*)(void *);
    using Reset = int (*)();

    Init init;
    SetDevice set_device;
    Malloc allocate;
    Memcpy copy;
    Free release;
    Reset reset;

    explicit HipApi(void *library)
      : init(reinterpret_cast<Init>(dlsym(library, "hipInit"))),
        set_device(reinterpret_cast<SetDevice>(dlsym(library, "hipSetDevice"))),
        allocate(reinterpret_cast<Malloc>(dlsym(library, "hipMalloc"))),
        copy(reinterpret_cast<Memcpy>(dlsym(library, "hipMemcpy"))),
        release(reinterpret_cast<Free>(dlsym(library, "hipFree"))),
        reset(reinterpret_cast<Reset>(dlsym(library, "hipDeviceReset")))
    {}

    [[nodiscard]] auto ready() const -> bool
    {
        return init != nullptr && set_device != nullptr && allocate != nullptr && copy != nullptr && release != nullptr
               && reset != nullptr;
    }
};

inline auto run_copy(const HipApi &api, int device) -> CopyStatus
{
    if (api.init(0) != 0) { return CopyStatus::InitFailed; }
    if (api.set_device(device) != 0) { return CopyStatus::DeviceFailed; }
    void *on_device = nullptr;
    const std::uint32_t value = 0;
    auto status = api.allocate(&on_device, sizeof(value)) == 0 ? CopyStatus::Ok : CopyStatus::AllocationFailed;
    if (status == CopyStatus::Ok && api.copy(on_device, &value, sizeof(value), 1) != 0) {
        status = CopyStatus::CopyFailed;
    }
    const int released = on_device != nullptr ? api.release(on_device) : 0;
    const int reset = api.reset();
    if (status == CopyStatus::Ok && released != 0) { status = CopyStatus::FreeFailed; }
    if (status == CopyStatus::Ok && reset != 0) { status = CopyStatus::ResetFailed; }
    return status;
}

inline auto copy_to_device(const char *library, int device) -> CopyStatus
{
    void *module = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (module == nullptr) { return CopyStatus::MissingLibrary; }
    const HipApi api(module);
    // The child's normal exit owns module teardown so process-global runtime callbacks remain valid.
    return api.ready() ? run_copy(api, device) : CopyStatus::MissingSymbols;
}

}// namespace kataglyphis::inference::hip_probe
#endif
