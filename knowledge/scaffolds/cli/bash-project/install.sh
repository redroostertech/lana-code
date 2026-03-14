#!/usr/bin/env bash
#
# install.sh - Install mycli to the system
#
set -euo pipefail

PREFIX="${1:-/usr/local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/mycli"

echo "Installing mycli to $PREFIX..."

# Create directories
mkdir -p "$BIN_DIR"
mkdir -p "$LIB_DIR"

# Copy library files
cp lib/*.sh "$LIB_DIR/"

# Install the main script (rewrite LIB_DIR to installed path)
sed "s|LIB_DIR=.*|LIB_DIR=\"$LIB_DIR\"|" bin/mycli > "$BIN_DIR/mycli"
chmod +x "$BIN_DIR/mycli"

echo "Installed mycli to $BIN_DIR/mycli"
echo "Run 'mycli help' to get started."
