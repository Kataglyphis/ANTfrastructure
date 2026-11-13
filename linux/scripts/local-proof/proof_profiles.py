"""Keep reviewed targeted-source scopes shared without granting image or GPU acceptance."""

TARGETED_STATUSES = {
    'sdk-llvm-prefix': 'passed-targeted-source-SDK-LLVM-prefix-repair-only',
    'native-clang-wrappers': 'passed-targeted-source-native-Clang-wrapper-and-backend-repair-only',
    'amd-inherited-toolchain': 'passed-targeted-source-AMD-inherited-toolchain-path-repair-only',
    'operational-tools': 'passed-targeted-source-operational-tool-preservation-only',
}
