#!/bin/bash
set -e

echo "Running formatters and tests..."

# Check if forge is available, if not, skip formatting
if command -v forge &> /dev/null; then
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
else
    echo "Warning: forge not found, skipping formatting, tests, and snapshots"
fi
