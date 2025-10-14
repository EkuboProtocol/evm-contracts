#!/bin/bash
set -e

echo "Running formatters..."

# Check if forge is available
if ! command -v forge &> /dev/null; then
    echo "Error: forge not found. Please run .mentat/setup.sh to install Foundry."
    exit 1
fi

# Check forge version and warn if it doesn't match CI
FORGE_VERSION=$(forge --version | grep -oP 'forge \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
EXPECTED_VERSION="1.4.0"

if [ "$FORGE_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "Warning: Local forge version ($FORGE_VERSION) differs from CI version ($EXPECTED_VERSION)"
    echo "This may cause formatting differences. Consider running: foundryup --version v$EXPECTED_VERSION"
fi

# Format Solidity files
echo "Formatting Solidity files..."
forge fmt

echo "Formatting complete!"
