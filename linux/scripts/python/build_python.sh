#!/bin/bash
set -e

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

PYTHON_VERSION=${1:-3.14.3}

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  echo "Skipping source-built host Python in cross mode; using target Python from the base rootfs"
  exit 0
fi

echo "Building Python ${PYTHON_VERSION} from source..."

wget "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" -O "/tmp/Python-${PYTHON_VERSION}.tgz"
tar -xf "/tmp/Python-${PYTHON_VERSION}.tgz" -C /tmp
cd "/tmp/Python-${PYTHON_VERSION}"
./configure --enable-shared --enable-optimizations --prefix=/usr/local
make -j$(nproc)
make altinstall

# Add the lib path to the system linker
echo "/usr/local/lib" > "/etc/ld.so.conf.d/python-${PYTHON_VERSION}.conf"
ldconfig

# Clean up
cd /
rm -rf "/tmp/Python-${PYTHON_VERSION}" "/tmp/Python-${PYTHON_VERSION}.tgz"
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Python ${PYTHON_VERSION} built and installed successfully."
