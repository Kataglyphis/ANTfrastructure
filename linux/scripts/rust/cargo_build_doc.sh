#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

# Extract crate name from Cargo.toml and format for rustdoc directory (replace dashes with underscores)
if [ ! -f "Cargo.toml" ]; then
    err "Cargo.toml not found in current directory"
    exit 1
fi

CRATE_NAME=$(grep -E '^name\s*=' Cargo.toml | head -n 1 | awk -F'"' '{print $2}')
if [ -z "$CRATE_NAME" ]; then
    err "Failed to extract crate name from Cargo.toml"
    exit 1
fi
CRATE_DIR_NAME="${CRATE_NAME//-/_}"
info "Detected crate name: $CRATE_NAME (doc dir: $CRATE_DIR_NAME)"

# Combine CSS files to create a custom rustdoc theme
# Assuming the ExternalLib submodule is available locally, or paths are provided
EXT_CSS=""
if [ -f "./ExternalLib/Kataglyphis-ContainerHub/docs/_static/css/custom.css" ]; then
    EXT_CSS="./ExternalLib/Kataglyphis-ContainerHub/docs/_static/css/custom.css"
elif [ -f "$SCRIPT_DIR/../../../docs/_static/css/custom.css" ]; then
    EXT_CSS="$SCRIPT_DIR/../../../docs/_static/css/custom.css"
fi

if [ -n "$EXT_CSS" ] && [ -f "./resources/web/rustdoc-mapping.css" ]; then
    info "Combining CSS files for custom rustdoc theme..."
    # Write combined theme directly into resources/web so it lives with other web assets
    cat "$EXT_CSS" ./resources/web/rustdoc-mapping.css > ./resources/web/combined-theme.css
    export RUSTDOCFLAGS="--extend-css ./resources/web/combined-theme.css"
fi

# Generate documentation without dependencies
info "Generating rust documentation (cargo doc --no-deps)..."
# Forward args to cargo doc (e.g. --features <feature>)
cargo doc --no-deps "$@"

# Provide a redirect from the root doc directory to the crate's docs
if [ -f "./resources/web/redirect/index.html" ]; then
    info "Providing redirect page..."
    cp ./resources/web/redirect/index.html ./target/doc/
fi

# Copy logo and images into the doc directory
if [ -f "./images/logo.png" ]; then
    info "Copying logo..."
    cp ./images/logo.png ./target/doc/logo.png
fi

if [ -d "./images" ]; then
    info "Copying images to target/doc/$CRATE_DIR_NAME/ ..."
    cp -r ./images "./target/doc/$CRATE_DIR_NAME/"
fi

info "Documentation built successfully."
