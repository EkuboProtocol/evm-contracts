#!/bin/bash
set -e

echo "Running formatters..."

# Check if forge is available, if not, skip formatting
if command -v forge &> /dev/null; then
    # Format Solidity files
    forge fmt
    echo "Formatting complete!"
else
    echo "Warning: forge not found, skipping formatting"
fi
