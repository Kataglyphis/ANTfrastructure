// Proof for the EP fix: a strided MIGraphX output becomes dense through a one-op "contiguous" program.
#include <migraphx/migraphx.hpp>
#include <hip/hip_runtime.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#define HIP_OK(x) do { hipError_t e = (x); if (e != hipSuccess) { std::printf("hip error %s at %d\n", hipGetErrorString(e), __LINE__); std::exit(2); } } while (0)

int main() {
  // The view the detector produced: lens [8,16,40,40], strides [32000,2000,40,1] (a slice of [8,16,50,40]).
  std::vector<size_t> lens{8, 16, 40, 40}, strides{32000, 2000, 40, 1};
  migraphx::shape view(migraphx_shape_float_type, lens, strides);
  migraphx::shape dense(migraphx_shape_float_type, lens);
  std::printf("view standard=%d bytes=%zu; dense bytes=%zu\n", view.standard(), view.bytes(), dense.bytes());

  auto t0 = std::chrono::steady_clock::now();
  migraphx::program p;
  auto mm = p.get_main_module();
  auto x = mm.add_parameter("x", view);
  auto c = mm.add_instruction(migraphx::operation("contiguous"), migraphx::instructions{x});
  mm.add_return(migraphx::instructions{c});
  p.compile(migraphx::target("gpu"));
  auto t1 = std::chrono::steady_clock::now();
  std::printf("compile %.1f ms\n", std::chrono::duration<double, std::milli>(t1 - t0).count());
  auto ps = p.get_parameter_shapes();
  for (auto&& n : ps.names()) {
    auto s = ps[n];
    std::printf("param %s standard=%d bytes=%zu lens=", n, s.standard(), s.bytes());
    for (auto l : s.lengths()) std::printf("%zu,", l);
    std::printf(" strides=");
    for (auto l : s.strides()) std::printf("%zu,", l);
    std::printf("\n");
  }
  auto os = p.get_output_shapes();
  std::printf("outputs=%zu output0 standard=%d\n", os.size(), os[0].standard());

  // Host truth: the big [8,16,50,40] tensor holds its flat index; the view selects rows 0..39.
  std::vector<float> big(8 * 16 * 50 * 40);
  for (size_t i = 0; i < big.size(); ++i) big[i] = static_cast<float>(i);
  void* d_big = nullptr; void* d_out = nullptr;
  HIP_OK(hipMalloc(&d_big, big.size() * sizeof(float)));
  HIP_OK(hipMalloc(&d_out, dense.bytes()));
  HIP_OK(hipMemcpy(d_big, big.data(), big.size() * sizeof(float), hipMemcpyHostToDevice));
  HIP_OK(hipMemset(d_out, 0xff, dense.bytes()));

  hipStream_t stream; HIP_OK(hipStreamCreate(&stream));
  migraphx::program_parameters pp;
  pp.add("x", migraphx::argument(view, d_big));
  std::string out_name;
  for (auto&& n : ps.names()) if (std::string(n).find("#output_") != std::string::npos) out_name = n;
  std::printf("binding %s\n", out_name.c_str());
  pp.add(out_name.c_str(), migraphx::argument(ps[out_name.c_str()], d_out));
  auto t2 = std::chrono::steady_clock::now();
  p.run_async(pp, stream);
  HIP_OK(hipStreamSynchronize(stream));
  auto t3 = std::chrono::steady_clock::now();
  std::printf("run %.3f ms\n", std::chrono::duration<double, std::milli>(t3 - t2).count());

  std::vector<float> out(dense.elements());
  HIP_OK(hipMemcpy(out.data(), d_out, dense.bytes(), hipMemcpyDeviceToHost));
  size_t bad = 0;
  for (size_t n = 0; n < 8; ++n) for (size_t ch = 0; ch < 16; ++ch) for (size_t h = 0; h < 40; ++h) for (size_t w = 0; w < 40; ++w) {
    float want = static_cast<float>(n * 32000 + ch * 2000 + h * 40 + w);
    float got = out[((n * 16 + ch) * 40 + h) * 40 + w];
    if (want != got) { if (bad < 3) std::printf("mismatch at %zu,%zu,%zu,%zu: want %g got %g\n", n, ch, h, w, want, got); ++bad; }
  }
  std::printf("%s: %zu of %zu elements wrong\n", bad ? "FAIL" : "PASS", bad, out.size());
  return bad ? 1 : 0;
}
