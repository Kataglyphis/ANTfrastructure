#!/usr/bin/env bash
set -euo pipefail

# NOTE: Keep LF line endings for Linux shells.

setup_flutter() {
	local arch_label="$1"
	local flutter_version="$2"
	local install_dir="${3:-/opt}"  # Default: /opt, override with 3rd argument
	local flutter_path="${install_dir}/flutter"
	local archive="flutter_linux_${flutter_version}-stable.tar.xz"

	echo "📦 Setting up Flutter ${flutter_version} for ${arch_label}..."
	echo "📁 Installation directory: ${flutter_path}"

	# Download Flutter SDK
	wget -q "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"

	# Extract to specified directory
	local SUDO=""
	if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
	$SUDO mkdir -p "${install_dir}"
	$SUDO tar xf "${archive}" -C "${install_dir}"

	# Remove downloaded archive to keep things clean
	rm -f "${archive}"

	# Add Flutter to PATH permanently for the current user
	local path_export="export PATH=\"${flutter_path}/bin:\$PATH\""
	if [ -f "$HOME/.bashrc" ]; then
		grep -q "${flutter_path}/bin" "$HOME/.bashrc" || echo "${path_export}" >> "$HOME/.bashrc"
	elif [ -f "$HOME/.profile" ]; then
		grep -q "${flutter_path}/bin" "$HOME/.profile" || echo "${path_export}" >> "$HOME/.profile"
	else
		echo "${path_export}" >> "$HOME/.profile"
	fi

	# Add Flutter to PATH for subsequent GitHub Action steps
	# echo "${flutter_path}/bin" >> "$GITHUB_PATH"

	# Add Flutter to PATH for current shell session
	export PATH="${flutter_path}/bin:$PATH"

	# Clean up unnecessary cache
	$SUDO rm -rf "${flutter_path}/bin/cache"

	# Verify installation
	flutter --version
}
