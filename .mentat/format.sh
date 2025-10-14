#!/bin/bash
set -e

echo "Running formatters..."

# Check if forge is available
if ! command -v forge &> /dev/null; then
    echo "Error: forge not found. Please run .mentat/setup.sh to install Foundry."
    exit 1
fi

# Check forge version and install correct version if needed
FORGE_VERSION=$(forge --version | grep -oP 'forge \K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
EXPECTED_VERSION="1.4.0"

if [ "$FORGE_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "Local forge version ($FORGE_VERSION) differs from CI version ($EXPECTED_VERSION)"
    echo "Installing forge v$EXPECTED_VERSION to match CI..."
    
    if command -v foundryup &> /dev/null; then
        foundryup --version "v$EXPECTED_VERSION"
        echo "Successfully installed forge v$EXPECTED_VERSION"
        
        # Use the newly installed forge from ~/.foundry/bin
        if [ -f "$HOME/.foundry/bin/forge" ]; then
            FORGE_BIN="$HOME/.foundry/bin/forge"
        else
            FORGE_BIN="forge"
        fi
    else
        echo "Warning: foundryup not found. Cannot auto-install correct forge version."
        echo "Please manually run: foundryup --version v$EXPECTED_VERSION"
        echo "Continuing with current version, but formatting may not match CI."
        FORGE_BIN="forge"
    fi
else
    FORGE_BIN="forge"
fi

# Format Solidity files
echo "Formatting Solidity files..."
$FORGE_BIN fmt

echo "Formatting complete!"
