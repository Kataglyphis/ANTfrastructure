#!/usr/bin/env bash
# runtime-cli.sh - shared CLI usage/environment documentation for runtime build scripts.

runtime_cli_usage_common() {
  cat <<'EOF'
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --image-prefix TAG            Prefix for built wrapper image tags
  --artifact-image-prefix TAG   Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE    Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH        Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH     Package Dockerfile (default: linux/Dockerfile.package)
  --torch-dockerfile PATH       Torch Dockerfile (default: linux/Dockerfile.torch)
  --torch-dockerfile PATH       Alias for --wrapper-dockerfile (deprecated)
  --wrapper-dockerfile PATH     Final wrapper Dockerfile (default: linux/Dockerfile.torch)
  --torch-app-mode MODE         TORCH_APP_MODE for linux/Dockerfile.torch
  --fast-ubuntu-mirror          Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL  Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                 Optional mirror URL for ubuntu-ports entries
EOF
}

runtime_cli_env_common() {
  cat <<'EOF'
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                               true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                               selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  TORCH_DOCKERFILE_PATH        Torch Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                Optional accelerator flag passed to package/torch/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/torch/wrapper builds
  ONNX_PACKAGE                 Optional torch ONNX package override
  PYTORCH_EXTRA                Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}
