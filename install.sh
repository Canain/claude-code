#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${TMPDIR:-/tmp}/claude-devcontainer-backup"
SSH_BACKUP_DIR="$BACKUP_DIR/ssh"
CLAUDE_BACKUP_DIR="$BACKUP_DIR/claude"

RESTORED=false

cleanup() {
    if [ "$RESTORED" = true ]; then
        rm -rf "$BACKUP_DIR"
    elif [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ] || [ -n "$(ls -A "$CLAUDE_BACKUP_DIR" 2>/dev/null)" ]; then
        echo ""
        echo "WARNING: Config was NOT restored to a new container."
        echo "Your backed-up data is preserved at: $BACKUP_DIR"
        echo "It will be restored automatically on the next run."
    else
        rm -rf "$BACKUP_DIR" 2>/dev/null || true
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

# Persist SSH keys and Claude config from running containers before teardown
# If a backup already exists from a previous failed run, keep it
if [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ] || [ -n "$(ls -A "$CLAUDE_BACKUP_DIR" 2>/dev/null)" ]; then
    echo "Found backup from a previous run at $BACKUP_DIR, reusing."
else
    echo "Backing up SSH keys and Claude config from running containers..."
    mkdir -p "$SSH_BACKUP_DIR" "$CLAUDE_BACKUP_DIR"
    for cid in $(docker ps -q --filter "label=devcontainer.local_folder=$SCRIPT_DIR"); do
        if docker exec "$cid" test -d /home/node/.ssh 2>/dev/null; then
            echo "  Saving SSH keys from container $cid..."
            docker cp "$cid:/home/node/.ssh/." "$SSH_BACKUP_DIR/" 2>/dev/null || true
        fi
        if docker exec "$cid" test -d /home/node/.claude 2>/dev/null; then
            echo "  Saving Claude config from container $cid..."
            docker cp "$cid:/home/node/.claude/." "$CLAUDE_BACKUP_DIR/" 2>/dev/null || true
        fi
        break
    done
fi

# Tear down old containers and images
echo "Tearing down old devcontainer containers and images..."

# Remove containers by devcontainer label (most reliable)
docker ps -a -q --filter "label=devcontainer.local_folder=$SCRIPT_DIR" | xargs -r docker rm -f 2>/dev/null || true

# Remove devcontainer images
for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}' | sort -u); do
    # Also catch any containers missed by label filter
    docker ps -a -q --filter "ancestor=$img" | xargs -r docker rm -f 2>/dev/null || true
    docker rmi -f "$img" 2>/dev/null || true
done

# Start devcontainer
echo "Building and starting devcontainer..."
if ! devcontainer up --workspace-folder "$SCRIPT_DIR"; then
    echo ""
    echo "ERROR: devcontainer up failed!"
    echo "Attempting recovery..."

    # Retry once from a clean state
    echo "Pruning broken containers and retrying..."
    docker ps -a -q --filter "label=devcontainer.local_folder=$SCRIPT_DIR" | xargs -r docker rm -f 2>/dev/null || true
    for img in $(docker images --format '{{.ID}} {{.Repository}}' | grep 'vsc-claude-code-' | awk '{print $1}' | sort -u); do
        docker ps -a -q --filter "ancestor=$img" | xargs -r docker rm -f 2>/dev/null || true
        docker rmi -f "$img" 2>/dev/null || true
    done

    if ! devcontainer up --workspace-folder "$SCRIPT_DIR"; then
        echo ""
        echo "ERROR: Recovery failed. devcontainer up failed twice."
        exit 1
    fi
fi

# Find new container
NEW_CID=$(docker ps -q --filter "label=devcontainer.local_folder=$SCRIPT_DIR" | head -1)

if [ -z "$NEW_CID" ]; then
    echo "WARNING: Could not find new container to restore config."
else
    # Restore SSH keys
    if [ -n "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]; then
        echo "Restoring SSH keys to new container..."
        docker exec "$NEW_CID" mkdir -p /home/node/.ssh
        docker cp "$SSH_BACKUP_DIR/." "$NEW_CID:/home/node/.ssh/"
        docker exec "$NEW_CID" chown -R node:node /home/node/.ssh
        docker exec "$NEW_CID" chmod 700 /home/node/.ssh
        docker exec "$NEW_CID" sh -c 'chmod 600 /home/node/.ssh/* 2>/dev/null; chmod 644 /home/node/.ssh/*.pub 2>/dev/null; true'
        echo "SSH keys restored."
    fi

    # Restore Claude config
    if [ -n "$(ls -A "$CLAUDE_BACKUP_DIR" 2>/dev/null)" ]; then
        echo "Restoring Claude config to new container..."
        docker exec "$NEW_CID" mkdir -p /home/node/.claude
        docker cp "$CLAUDE_BACKUP_DIR/." "$NEW_CID:/home/node/.claude/"
        docker exec "$NEW_CID" chown -R node:node /home/node/.claude
        echo "Claude config restored."
    fi

    RESTORED=true
fi

if [ -z "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ] && [ -z "$(ls -A "$CLAUDE_BACKUP_DIR" 2>/dev/null)" ]; then
    echo "No config to restore."
    RESTORED=true
fi
