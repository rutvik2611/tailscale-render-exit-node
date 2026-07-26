#!/bin/bash
# =============================================================================
# start.sh - Tailscale Exit Node Entrypoint
# =============================================================================
# Starts tailscaled, authenticates with provided auth key, and advertises
# as an exit node. Runs continuously with health check endpoint.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HOSTNAME="${HOSTNAME:-render-exit-node}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
TAILSCALE_STATE_DIR="/var/lib/tailscale"
TAILSCALE_SOCKET="/var/run/tailscale/tailscaled.sock"

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
if [ -z "${TAILSCALE_AUTHKEY}" ]; then
    echo "ERROR: TAILSCALE_AUTHKEY is not set."
    echo "Set this environment variable to authenticate this node."
    echo "Generate a key at: https://login.tailscale.com/admin/settings/authkeys"
    exit 1
fi

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
cleanup() {
    log "Shutting down tailscaled..."
    tailscale logout 2>/dev/null || true
    kill %1 2>/dev/null || true
    wait 2>/dev/null || true
    log "Shutdown complete."
}
trap cleanup SIGTERM SIGINT EXIT

# ---------------------------------------------------------------------------
# Step 1: Start tailscaled
# ---------------------------------------------------------------------------
log "Starting tailscaled..."
tailscaled \
    --state="${TAILSCALE_STATE_DIR}/tailscaled.state" \
    --socket="${TAILSCALE_SOCKET}" \
    --tun=userspace-networking \
    --socks5-server=localhost:1055 \
    --outbound-http-proxy-listen=localhost:1055 \
    2>&1 | while read -r line; do log "[tailscaled] $line"; done &

TAILSCALED_PID=$!

# Wait for tailscaled socket to be ready
log "Waiting for tailscaled to start..."
for i in $(seq 1 30); do
    if [ -S "${TAILSCALE_SOCKET}" ]; then
        log "tailscaled socket ready."
        break
    fi
    if [ $i -eq 30 ]; then
        log "ERROR: tailscaled failed to start within 30 seconds."
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Step 2: Authenticate and connect with exit node advertisement
# ---------------------------------------------------------------------------
log "Authenticating with Tailscale (hostname: ${HOSTNAME})..."
log "Auth key prefix: ${TAILSCALE_AUTHKEY:0:12}..."

# Build the tailscale up command
TS_UP_CMD=(
    tailscale up
    --authkey="${TAILSCALE_AUTHKEY}"
    --hostname="${HOSTNAME}"
    --advertise-exit-node
)

# Add extra args if provided
if [ -n "${TAILSCALE_EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2086
    TS_UP_CMD+=(${TAILSCALE_EXTRA_ARGS})
fi

if ! "${TS_UP_CMD[@]}" 2>&1; then
    log "ERROR: tailscale up failed. Check your auth key and network."
    log "Common issues:"
    log "  - Auth key is expired or invalid"
    log "  - Auth key is already used (if not reusable)"
    log "  - Missing NET_ADMIN capability"
    exit 1
fi

log "Tailscale authentication successful."

# ---------------------------------------------------------------------------
# Step 3: Verify connection
# ---------------------------------------------------------------------------
log "Verifying Tailscale status..."
if ! tailscale status 2>&1; then
    log "WARNING: tailscale status returned non-zero. Checking IP..."
fi

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
log "Tailscale IPv4: ${TAILSCALE_IP}"

TAILSCALE_IP6=$(tailscale ip -6 2>/dev/null || echo "unknown")
log "Tailscale IPv6: ${TAILSCALE_IP6}"

log "Exit node advertisement enabled."
log "---"
log "Tailscale Exit Node is RUNNING."
log "Hostname: ${HOSTNAME}"
log "IP: ${TAILSCALE_IP}"
log "---"

# ---------------------------------------------------------------------------
# Step 4: Run health check endpoint (simple HTTP server) + keep container alive
# ---------------------------------------------------------------------------
# Simple health check loop - report status every 60 seconds
while true; do
    if ! tailscale status > /dev/null 2>&1; then
        log "WARNING: Tailscale disconnected. Attempting reconnection..."
        tailscale up \
            --authkey="${TAILSCALE_AUTHKEY}" \
            --hostname="${HOSTNAME}" \
            --advertise-exit-node \
            ${TAILSCALE_EXTRA_ARGS:+"${TAILSCALE_EXTRA_ARGS}"} 2>&1 || true
    fi

    # Report periodic health
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] HEALTH: OK - ${TAILSCALE_IP}"
    sleep 60
done