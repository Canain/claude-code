#!/bin/bash
set -euo pipefail

# Start Tailscale and enable SSH access
# Requires TS_AUTHKEY environment variable (Tailscale auth key)
# Generate one at: https://login.tailscale.com/admin/settings/keys

if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "WARNING: TS_AUTHKEY not set, skipping Tailscale setup."
    echo "To enable Tailscale, set TS_AUTHKEY in your environment or .env file."
    exit 0
fi

echo "Starting Tailscale daemon..."
tailscaled --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 &>/var/log/tailscaled.log &

# Wait for daemon to be ready
for i in $(seq 1 10); do
    if tailscale status &>/dev/null; then
        break
    fi
    sleep 1
done

echo "Connecting to Tailscale with SSH enabled..."
tailscale up --authkey="$TS_AUTHKEY" --ssh --hostname="claude-sandbox"

echo "Tailscale is up. SSH access enabled."
tailscale status
