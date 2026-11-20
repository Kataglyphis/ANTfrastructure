#!/usr/bin/env bash
# Checked shared Git setup keeps source-preservation controls independent of the copier.
set -euo pipefail
fixture_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${fixture_dir}/test-harness.sh"
source "${fixture_dir}/git-fixture-env.sh"
plant_consumer_source() {
    printf 'versioned fixture\n' > "$1/source.txt"
    if [ "$2" != vendored ]; then
        git -C "$1" config --file .gitmodules submodule.fixture.path third_party/ANTfrastructure
        git -C "$1" config --file .gitmodules submodule.fixture.url "$1/third_party/ANTfrastructure"
    fi
}
t_consumer_fixture "$1" plant_consumer_source root vendored
