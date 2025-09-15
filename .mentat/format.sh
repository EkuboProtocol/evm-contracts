#!/bin/bash
set -e

echo "Running formatters..."

# Format Solidity files
forge fmt

echo "Formatting complete!"
