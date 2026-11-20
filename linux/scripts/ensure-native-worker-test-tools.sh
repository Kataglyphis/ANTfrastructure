#!/usr/bin/env bash
# Fixture tools and the pinned Dart SDK do not establish a CI result or an installed application bridge.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/lib/cli-value-options.sh
source "${scripts}/lib/cli-value-options.sh"
cli_require_positionals 'FLUTTER_PARENT_DIRECTORY' 1 1 "$@"
for tool in cc c++ rustc sccache; do "${tool}" --version; done
# shellcheck source=linux/scripts/05-frameworks/flutter/flutter-pin.sh
source "${scripts}/05-frameworks/flutter/flutter-pin.sh"
unset FLUTTER_VERSION FLUTTER_SDK_SHA256
flutter_resolve_pin
: "${FLUTTER_VERSION:?}" "${FLUTTER_SDK_SHA256:?}"
bash "${scripts}/05-frameworks/flutter/setup-flutter.sh" --arch x64 \
  --version "${FLUTTER_VERSION}" --dir "$1" --keep-cache
dart_binary="$1/flutter/bin/cache/dart-sdk/bin/dart"
"${dart_binary}" --version
