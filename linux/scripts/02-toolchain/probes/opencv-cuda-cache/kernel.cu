__global__ void cache_kernel(int* output) {
#if defined(__CUDA_ARCH__)
  output[threadIdx.x] = __CUDA_ARCH__;
#else
  output[threadIdx.x] = 0;
#endif
}
