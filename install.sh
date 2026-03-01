#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_BACKUP_DIR="${TMPDIR:-/tmp}/claude-devcontainer-ssh-backup"

SSH_RESTORED=false

cleanup() {
    if [ "$SSH_RESTORED" = true ]; then
        rm -rf "$SSH_BACKUP_DIR"
    elif [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]; then
        echo ""
        echo "WARNING: SSH keys were NOT restored to a new container."
        echo "Your backed-up SSH keys are preserved at: $SSH_BACKUP_DIR"
        echo "They will be restored automatically on the next run."
    else
        rm -rf "$SSH_BACKUP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

# Persist SSH keys from running containers before teardown
# If a backup already exists from a previous failed run, keep it
if [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]; then
    echo "Found SSH keys from a previous run at $SSH_BACKUP_DIR, reusing."
else
    echo "Backing up SSH keys from running containers..."
    mkdir -p "$SSH_BACKUP_DIR"
    for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}'); do
        for cid in $(docker ps -q --filter "ancestor=$img"); do
            if docker exec "$cid" test -d /home/node/.ssh 2>/dev/null; then
                echo "  Saving SSH keys from container $cid..."
                docker cp "$cid:/home/node/.ssh/." "$SSH_BACKUP_DIR/" 2>/dev/null || true
                break 2
            fi
        done
    done
fi

# Tear down old containers and images
echo "Tearing down old devcontainer containers and images..."
for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}'); do
    docker ps -a -q --filter "ancestor=$img" | xargs -r docker rm -f || true
    docker rmi "$img" || true
done

# Start devcontainer
echo "Building and starting devcontainer..."
if ! devcontainer up --workspace-folder "$SCRIPT_DIR"; then
    echo ""
    echo "ERROR: devcontainer up failed!"
    echo "Attempting recovery..."

    # Retry once from a clean state
    echo "Pruning broken containers and retrying..."
    for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}'); do
        docker ps -a -q --filter "ancestor=$img" | xargs -r docker rm -f || true
        docker rmi "$img" || true
    done

    if ! devcontainer up --workspace-folder "$SCRIPT_DIR"; then
        echo ""
        echo "ERROR: Recovery failed. devcontainer up failed twice."
        exit 1
    fi
fi

# Restore SSH keys into the new container
if [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]; then
    echo "Restoring SSH keys to new container..."
    NEW_CID=$(docker ps -q --filter "ancestor=$(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}' | head -1)" | head -1)
    if [ -n "$NEW_CID" ]; then
        docker exec "$NEW_CID" mkdir -p /home/node/.ssh
        docker cp "$SSH_BACKUP_DIR/." "$NEW_CID:/home/node/.ssh/"
        docker exec "$NEW_CID" chown -R node:node /home/node/.ssh
        docker exec "$NEW_CID" chmod 700 /home/node/.ssh
        docker exec "$NEW_CID" sh -c 'chmod 600 /home/node/.ssh/* 2>/dev/null; chmod 644 /home/node/.ssh/*.pub 2>/dev/null; true'
        SSH_RESTORED=true
        echo "SSH keys restored."
    else
        echo "WARNING: Could not find new container to restore SSH keys."
    fi
else
    echo "No SSH keys to restore."
    SSH_RESTORED=true
fi
