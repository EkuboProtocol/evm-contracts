#!/bin/bash
set -e

echo "Setting up Ekubo Protocol development environment..."

# Install foundry if not already installed
if ! command -v forge &> /dev/null; then
    echo "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
fi

# Install dependencies
echo "Installing forge dependencies..."
forge install

echo "Building contracts..."
forge build

echo "Setup complete!"
