#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install nvm if not present
if ! command -v nvm &>/dev/null && [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    echo "Installing nvm..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
. "$NVM_DIR/nvm.sh"

# Install Node 20 if node not available
if ! command -v node &>/dev/null; then
    echo "Installing Node 20..."
    nvm install 20
fi

# Install devcontainers CLI
if ! command -v devcontainer &>/dev/null; then
    echo "Installing @devcontainers/cli..."
    npm install -g @devcontainers/cli
fi

# Tear down old containers and images
echo "Tearing down old devcontainer containers and images..."
for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-devs-' | awk '{print $1}'); do
    docker ps -a -q --filter "ancestor=$img" | xargs -r docker rm -f || true
    docker rmi "$img" || true
done

# Start devcontainer
echo "Building and starting devcontainer..."
if ! devcontainer up --workspace-folder "$SCRIPT_DIR"; then
    echo ""
    echo "ERROR: devcontainer up failed!"
    exit 1
fi
