#!/usr/bin/env bash
# Setup reads only the preserved snapshot, so later worktree edits cannot alter an active proof.
set -euo pipefail
task_source=/tmp/isolated-preflight-source
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git make build-essential binutils \
  patchelf file xz-utils zip unzip pkg-config python3 python3-venv sudo util-linux \
  nodejs npm libicu-dev libgssapi-krb5-2 libssl-dev zlib1g zlib1g-dev python3-dev jq shellcheck rsync procps psmisc locales
localedef -i en_US -f UTF-8 en_US.UTF-8
LC_ALL=en_US.UTF-8 locale charmap
mkdir -p "${task_source}"
cp -a /source/. "${task_source}/"
test "$(git -c safe.directory="${task_source}" -C "${task_source}" rev-parse HEAD)" = "${ISOLATED_PREFLIGHT_REVISION:?}"
source "${task_source}/linux/scripts/01-core/load-versions-env.sh"
unset UV_VERSION
load_versions_env "${task_source}/linux/scripts/01-core/versions.env"
bash "${task_source}/linux/scripts/01-core/base-image.sh" install-uv --version "${UV_VERSION:?}"
source "${task_source}/linux/scripts/01-core/downloads.sh"
source "${task_source}/linux/scripts/06-packaging/package-image-wiring.sh"
install_pwsh "${task_source}/linux/scripts/01-core/versions.env" /usr/local/share/powershell/7 /usr/local/bin
uv venv /opt/preflight-venv --python /usr/bin/python3
/opt/preflight-venv/bin/python -m ensurepip --upgrade
uv export --project "${task_source}/quality" --locked --no-dev --no-emit-project \
  --format requirements-txt --output-file /tmp/preflight-quality.txt
uv pip install --python /opt/preflight-venv/bin/python --require-hashes --requirement /tmp/preflight-quality.txt
bash "${task_source}/linux/scripts/ensure-pe-icon-test-tools.sh" --install-missing
PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright /opt/preflight-venv/bin/python -m playwright install --with-deps chromium
task_chrome="$(PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright /opt/preflight-venv/bin/python -c 'from playwright.sync_api import sync_playwright; p=sync_playwright().start(); print(p.chromium.executable_path); p.stop()')"
test -x "${task_chrome}"
ln -s "${task_chrome}" /usr/local/bin/chromium
if ! getent passwd 1000 >/dev/null; then useradd --uid 1000 --create-home preflight; fi
mkdir -p /tmp/isolated-preflight-home
chown 1000:1000 /tmp/isolated-preflight-home
chown -R 1000:1000 "${task_source}"
dpkg-query -W jq shellcheck zlib1g-dev python3-dev gcc libc6 rustc cargo cmake ninja-build locales > /evidence/prerequisites.txt
exec setpriv --reuid 1000 --regid 1000 --init-groups env -i \
  PATH=/opt/preflight-venv/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/tmp/isolated-preflight-home LC_ALL=C PYTHON_CPU_COUNT="${ISOLATED_PREFLIGHT_JOBS:?}" \
  PREFLIGHT_JOBS="${ISOLATED_PREFLIGHT_JOBS}" RUN_TESTS_JOBS="${ISOLATED_PREFLIGHT_JOBS}" \
  LINT_SHELL_JOBS="${ISOLATED_PREFLIGHT_JOBS}" UV_CACHE_DIR=/tmp/isolated-preflight-home/.cache/uv \
  CHROME_EXECUTABLE=/usr/local/bin/chromium PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright \
  ISOLATED_PREFLIGHT_REVISION="${ISOLATED_PREFLIGHT_REVISION}" \
  /bin/bash "${task_source}/linux/scripts/isolated-preflight/worker.sh"
