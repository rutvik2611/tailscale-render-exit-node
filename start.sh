#!/bin/bash
# =============================================================================
# start.sh - Tailscale Exit Node Entrypoint
# =============================================================================
set -euo pipefail

HOSTNAME="${HOSTNAME:-renderfn-exit}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
TAILSCALE_STATE_DIR="/var/lib/tailscale"
TAILSCALE_SOCKET="/var/run/tailscale/tailscaled.sock"
PORT="${PORT:-8080}"

if [ -z "${TAILSCALE_AUTHKEY}" ]; then
    echo "ERROR: TAILSCALE_AUTHKEY is not set."
    exit 1
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

cleanup() {
    log "Shutting down tailscaled..."
    tailscale logout 2>/dev/null || true
    kill %1 %2 2>/dev/null || true
    wait 2>/dev/null || true
    log "Shutdown complete."
}
trap cleanup SIGTERM SIGINT EXIT

# Step 1: Start HTTP health server (background)
log "Starting HTTP health endpoint on port ${PORT}..."
export PORT
python3 -u /usr/local/bin/health_server.py &
HEALTH_PID=$!
sleep 1

# Step 2: Start tailscaled
log "Starting tailscaled..."
tailscaled \
    --state="${TAILSCALE_STATE_DIR}/tailscaled.state" \
    --socket="${TAILSCALE_SOCKET}" \
    --tun=userspace-networking \
    --socks5-server=localhost:1055 \
    --outbound-http-proxy-listen=localhost:1055 \
    2>&1 | while read -r line; do log "[tailscaled] $line"; done &

TAILSCALED_PID=$!

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

# Step 3: Authenticate
log "Authenticating with Tailscale (hostname: ${HOSTNAME})..."

TS_UP_CMD=(
    tailscale up --reset
    --authkey="${TAILSCALE_AUTHKEY}"
    --hostname="${HOSTNAME}"
    --advertise-exit-node
    --accept-routes
)
if [ -n "${TAILSCALE_EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2086
    TS_UP_CMD+=(${TAILSCALE_EXTRA_ARGS})
fi

if ! "${TS_UP_CMD[@]}" 2>&1; then
    log "ERROR: tailscale up failed."
    exit 1
fi
log "Tailscale authentication successful."

# Step 4: Verify
log "Verifying Tailscale status..."
tailscale status 2>&1 || true
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
TAILSCALE_IP6=$(tailscale ip -6 2>/dev/null || echo "unknown")

log "---"
log "Tailscale Exit Node is RUNNING."
log "Hostname: ${HOSTNAME}"
log "IP: ${TAILSCALE_IP}"
log "Status: https://0.0.0.0:${PORT}/status"
log "Health:  https://0.0.0.0:${PORT}/health"
log "---"

# Step 5: Self-healing loop
while true; do
    if ! tailscale status > /dev/null 2>&1; then
        log "WARNING: Tailscale disconnected. Attempting reconnection..."
        tailscale up --reset \
            --authkey="${TAILSCALE_AUTHKEY}" \
            --hostname="${HOSTNAME}" \
            --advertise-exit-node \
            --accept-routes \
            ${TAILSCALE_EXTRA_ARGS:+"${TAILSCALE_EXTRA_ARGS}"} 2>&1 || true
    fi

    TS_IP=$(tailscale ip -4 2>/dev/null || echo "disconnected")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] HEALTH: OK - ${TS_IP}"

    if ! kill -0 "${HEALTH_PID}" 2>/dev/null; then
        log "WARNING: HTTP health server died. Restarting..."
        python3 -u /usr/local/bin/health_server.py &
        HEALTH_PID=$!
    fi

    sleep 60
done