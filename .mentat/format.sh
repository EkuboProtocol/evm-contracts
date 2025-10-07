#!/bin/bash
set -e

echo "Running formatters and tests..."

# Check if forge is available
if ! command -v forge &> /dev/null; then
    echo "Error: forge not found. Please run .mentat/setup.sh to install Foundry."
    exit 1
fi

# Format Solidity files
echo "Formatting Solidity files..."
forge fmt

# Run tests
echo "Running tests..."
forge test

# Update gas snapshots
echo "Updating gas snapshots..."
forge snapshot

echo "Format, tests, and snapshots complete!"
