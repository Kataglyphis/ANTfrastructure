#!/bin/bash
set -e

PYTHON_VERSION=${1:-3.14.3}

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
