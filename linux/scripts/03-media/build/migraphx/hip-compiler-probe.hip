#include <hip/hip_runtime.h>

extern "C" __global__ void ant_hip_probe(float* values)
{
    values[threadIdx.x] = __builtin_sqrtf(values[threadIdx.x]);
}
