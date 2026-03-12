#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CID=$(docker ps -q --filter "label=devcontainer.local_folder=$SCRIPT_DIR" | head -1)

if [ -z "$CID" ]; then
    echo "ERROR: No running devcontainer found. Run wsl.sh first."
    exit 1
fi

docker exec -it -u node -w /workspace "$CID" zsh
