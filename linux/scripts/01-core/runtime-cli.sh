#!/usr/bin/env bash
# runtime-cli.sh - shared CLI argument parsing for runtime build scripts.

parse_runtime_cli_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --architectures|--target-arches)
        TARGET_ARCHES="$2"
        shift 2
        ;;
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --image-prefix|--image)
        IMAGE_PREFIX="$2"
        IMAGE_NAME="$2"
        shift 2
        ;;
      --artifact-image-prefix)
        ARTIFACT_IMAGE_PREFIX="$2"
        shift 2
        ;;
      --artifact-build-mode)
        ARTIFACT_BUILD_MODE="$2"
        shift 2
        ;;
      --base-dockerfile)
        BASE_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --package-dockerfile)
        PACKAGE_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --torch-dockerfile)
        TORCH_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --wrapper-dockerfile)
        WRAPPER_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --torch-app-mode)
        TORCH_APP_MODE="$2"
        shift 2
        ;;
      --fast-ubuntu-mirror)
        USE_FAST_UBUNTU_MIRROR=true
        shift
        ;;
      --fast-ubuntu-mirror-url)
        USE_FAST_UBUNTU_MIRROR=true
        FAST_UBUNTU_MIRROR_URL="$2"
        shift 2
        ;;
      --fast-ubuntu-ports-mirror-url)
        USE_FAST_UBUNTU_MIRROR=true
        FAST_UBUNTU_PORTS_MIRROR_URL="$2"
        shift 2
        ;;
      --push)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        shift
        ;;
      --push-images)
        PUSH_IMAGES=1
        shift
        ;;
      --push-manifest)
        PUSH_MANIFEST=1
        shift
        ;;
      --push-all)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        PUSH_INTERMEDIATE_IMAGES=1
        shift
        ;;
      --skip-manifest)
        CREATE_MANIFEST=0
        shift
        ;;
      --manifest-only)
        BUILD_IMAGES=0
        shift
        ;;
      -h|--help)
        return 1
        ;;
      *)
        printf '[ERROR] Unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done
}

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
