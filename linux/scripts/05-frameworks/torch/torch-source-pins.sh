#!/usr/bin/env bash
# Torch's Git tag and package version use different spellings of the same release.
resolve_torch_source_refs() {
    local version_tag_re='^v?[0-9]+\.[0-9]+'
    if [ -z "${PYTORCH_VERSION:-}" ] && [ -z "${PYTORCH_REF:-}" ]; then
        printf '%s\n' 'Torch source pin missing: set PYTORCH_VERSION or PYTORCH_REF' >&2
        return 1
    fi
    if [ -z "${TORCHVISION_VERSION:-}" ] && [ -z "${TORCHVISION_REF:-}" ]; then
        printf '%s\n' 'TorchVision source pin missing: set TORCHVISION_VERSION or TORCHVISION_REF' >&2
        return 1
    fi
    if [ -z "${PYTORCH_VERSION:-}" ] && [[ ! "${PYTORCH_REF}" =~ $version_tag_re ]]; then
        printf '%s\n' 'Torch package version is required for a non-release source ref' >&2
        return 1
    fi
    : "${PYTORCH_REF:=${PYTORCH_VERSION}}"
    : "${TORCHVISION_REF:=${TORCHVISION_VERSION}}"
    : "${PYTORCH_VERSION:=${PYTORCH_REF#v}}"
    if [[ "${PYTORCH_REF}" =~ $version_tag_re && "${PYTORCH_REF#v}" != "${PYTORCH_VERSION#v}" ]]; then
        printf '%s\n' 'Torch source ref and package version differ' >&2
        return 1
    fi
    if [[ "${TORCHVISION_REF}" =~ $version_tag_re && -n "${TORCHVISION_VERSION:-}" && "${TORCHVISION_REF#v}" != "${TORCHVISION_VERSION#v}" ]]; then
        printf '%s\n' 'TorchVision source ref and version differ' >&2
        return 1
    fi
    PYTORCH_VERSION="${PYTORCH_VERSION#v}"
}
