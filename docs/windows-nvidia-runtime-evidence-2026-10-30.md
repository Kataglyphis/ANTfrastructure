# Windows NVIDIA runtime provenance, 2026-10-30

This is an observation of the cached `:winamd64-nvidia` image with digest
`sha256:b472f91ba9553937a1c62f476ef6d01a878db4d44c754091ece08fb21ba11777`, not a
contract for later mutable tags. Its `C:\runtime\cuda-runtime\bin` contains the 31
DLLs below, totalling 2,153,180,048 bytes. Each SHA-256 was computed from the
flattened DLL and matched exactly one same-named file under the source SDK roots:

- CUDA: `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin\x64`.
- cuDNN: `C:\Program Files\NVIDIA\CUDNN\v9.27.0.42\bin\x64`.

The source CUDA `LICENSE` SHA-256 is
`088381bc2d891e719a2a9398645b00bb45f3b24231473a8283ac7e3e66b8a028`;
the cuDNN `LICENSE` SHA-256 is
`295a1b7118d3417f5d6a943e5f87b59e2a0631fb277129c3b15dee6248adc7cf`.
The flattened runtime has no accompanying origin or redistribution manifest. The
image's cuDNN supplement describes the runtime DLLs as distributable subject to
its agreement; the CUDA license lists specific distributable toolkit families.
Confirm each file and the applicable terms before shipping it. In particular,
the installed CUDA license mentions `nvfatbin` in third-party notices, but its
status in the version-specific distributable-file list has not been established.

The CUDA provider directly imports `cublas64_13.dll` and `cublasLt64_13.dll`;
other CUDA and cuDNN files may be loaded dynamically. This inventory alone does
not prove the runtime set is complete for all models or that GPU inference runs.
The NVIDIA display driver remains a host dependency and is not in this set.

| Flattened DLL | Source SDK | SHA-256 |
| --- | --- | --- |
| `cublas64_13.dll` | cuda | `60bbba8868290311e9c1657b2193ddec667744eb555ff843f87acb7c039f9efa` |
| `cublasLt64_13.dll` | cuda | `cad63434448e7141629e240ea093ad596a7ef6a0f67b468ba9bc1df6e1eeee33` |
| `cudart64_13.dll` | cuda | `d26fd1c2629594759af569a5252f94e4568d4ebeca67dc323834deb141aa278a` |
| `cudnn_adv64_9.dll` | cudnn | `041cab1d6439d2558b4a7073a42dd95058d0395463ffb0d37275af11ec0af8d7` |
| `cudnn_cnn64_9.dll` | cudnn | `7dd1bcc6d8f00ad635f6a8a2cd076faba21626f3412e13c61a6bece3f88eacb1` |
| `cudnn_engines_precompiled64_9.dll` | cudnn | `5d9b829228ae18594dafedf718d9612606c8ce6d199aa7151bea53e863baeefe` |
| `cudnn_engines_runtime_compiled64_9.dll` | cudnn | `8e65eeb0a4a3b7afa48ea3ca71c4b88e355199f85485b6fc0badcc97ebc552ef` |
| `cudnn_engines_tensor_ir64_9.dll` | cudnn | `51afb44ce4b901ccdac1434f9fc9d8d707b690f39ae1e2a6ffca98c5fd9dfa96` |
| `cudnn_ext64_9.dll` | cudnn | `a0e0e2e8e8e4678956bbef93fdccc4730bd5edf9b23d38bff49030ebba1940a6` |
| `cudnn_graph64_9.dll` | cudnn | `ccc90435b2fd37b5ddd6a9fa0fd053ad8f46c2dc8b0a6256ef0ebea7f3efbace` |
| `cudnn_heuristic64_9.dll` | cudnn | `c0439ee74a3dbec8ecf56fecbc6ac2506efcce702453e36119649545d02509c3` |
| `cudnn_ops64_9.dll` | cudnn | `2bd7f4122eaeccb85538c2a6f7923d7254ad77d7b7149fed0a8139f1e3cf0b07` |
| `cudnn64_9.dll` | cudnn | `0016bd73ac9192537ae5af6a3f05814316726dad1d1da44f113f0a9ef00ae34c` |
| `cufft64_12.dll` | cuda | `d353fd42da7729709864731f35888aa177793d2350e56557df4c6ebaaf079ace` |
| `cufftw64_12.dll` | cuda | `003a0eb70e1e681bf006f969be613925df282f493bf67402f493f4c787c54b75` |
| `curand64_10.dll` | cuda | `2ae1d341cd7da1dab91e2215c62f627e0e0288ff54cdc9003e908746584b5b2b` |
| `nppc64_13.dll` | cuda | `cd6ae21ae5b28108e49a94724b179eede833c16be9e50846ba5f580ff3c7ef8b` |
| `nppial64_13.dll` | cuda | `ccb04f2b3ee02028f18df761fd3b6711e57da09676cde2b75b02063a1ee30ef5` |
| `nppicc64_13.dll` | cuda | `7a5078b2611f89ed7dfb7bbfef196618e92ff42647c91d6dd816fcf83b7d1da7` |
| `nppidei64_13.dll` | cuda | `9c2ad0006119368498cd7fdf28e3cd220be602bd522744c2c7375e1ceeefad5c` |
| `nppif64_13.dll` | cuda | `66966577d648e3d7ebe3863c7a22da0a16bba6e45c0fc2dcb57b3faee9b7cafb` |
| `nppig64_13.dll` | cuda | `81ad418d5d6965dc248be6a509c639db2856c586fb7e99afa6bfd140dca99390` |
| `nppim64_13.dll` | cuda | `331b5a766a0166a8598aa60e1755f12a37e5c94c7e406610fb4c06fbc926e157` |
| `nppist64_13.dll` | cuda | `862611db86e32731771aa4dd2f48f987d04514793404ac364938520b3453ca3f` |
| `nppisu64_13.dll` | cuda | `611fed92a40d0bdc1baf8b3e8b936bfdb1d2711c26fff67072bf0119a71c2326` |
| `nppitc64_13.dll` | cuda | `5ff93cb8ff36968a8967b72bec9772d3664cbb05f1116a8cb3385a08a092fc33` |
| `nvblas64_13.dll` | cuda | `9c4a77a3f460641dcb55073d50aa832e0cefe92f11a7a5a587bde658e2d5ac4b` |
| `nvfatbin_130_0.dll` | cuda | `b48b1d3af9a8d764f4f00fd17e39cee34684fe371231a0df4ab26eb652ba66fa` |
| `nvJitLink_130_0.dll` | cuda | `6044faf21b4979502588ff9319521dd21a42b9068239d3291e53bc5a063b09bf` |
| `nvrtc-builtins64_134.dll` | cuda | `73768e90526e8a43d5eb356f0ffad198468e8c15e95d45a84c6c4b12fb9aa02f` |
| `nvrtc64_130_0.dll` | cuda | `c92027e5eae58b6f272cafb438bf59b55deb02bd326b183956e84e0a180dbd14` |
