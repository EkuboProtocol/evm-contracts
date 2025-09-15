#!/bin/bash
set -e

echo "Running tests..."

# Run forge tests with any additional arguments passed to the script
forge test "$@"

echo "Tests complete!"
