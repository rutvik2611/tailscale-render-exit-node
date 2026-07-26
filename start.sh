#!/bin/bash
# =============================================================================
# start.sh - Tailscale Exit Node Entrypoint
# =============================================================================
# Starts tailscaled, authenticates with provided auth key, and advertises
# as an exit node. Includes a lightweight HTTP health/wakeup endpoint
# for Render's health checks and uptime monitoring.
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
PORT="${PORT:-8080}"

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
    kill %1 %2 2>/dev/null || true
    wait 2>/dev/null || true
    log "Shutdown complete."
}
trap cleanup SIGTERM SIGINT EXIT

# ---------------------------------------------------------------------------
# Step 1: Start lightweight HTTP health server (background)
# ---------------------------------------------------------------------------
# This endpoint responds to Render's health checks and external uptime monitors.
# GET / returns 200 OK with health status.
log "Starting HTTP health endpoint on port ${PORT}..."
python3 -u -c "
import http.server, json, os, sys

PORT = int(os.environ.get('PORT', 8080))

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'status': 'alive',
                'service': 'tailscale-exit-node',
                'hostname': os.environ.get('HOSTNAME', 'unknown')
            }).encode())
        elif self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'TAILSCALE EXIT NODE - HEALTH OK\n')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        # Quiet logging
        pass

server = http.server.HTTPServer(('0.0.0.0', PORT), HealthHandler)
sys.stdout.write(f'[HEALTH] HTTP server listening on port {PORT}\n')
sys.stdout.flush()
server.serve_forever()
" &

HEALTH_PID=$!
sleep 1

# ---------------------------------------------------------------------------
# Step 2: Start tailscaled
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
# Step 3: Authenticate and connect with exit node advertisement
# ---------------------------------------------------------------------------
log "Authenticating with Tailscale (hostname: ${HOSTNAME})..."

# Build the tailscale up command
TS_UP_CMD=(
    tailscale up
    --reset
    --authkey="${TAILSCALE_AUTHKEY}"
    --hostname="${HOSTNAME}"
    --advertise-exit-node
    --accept-routes
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
# Step 4: Verify connection
# ---------------------------------------------------------------------------
log "Verifying Tailscale status..."
tailscale status 2>&1 || true

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
log "Tailscale IPv4: ${TAILSCALE_IP}"

TAILSCALE_IP6=$(tailscale ip -6 2>/dev/null || echo "unknown")
log "Tailscale IPv6: ${TAILSCALE_IP6}"

log "Exit node advertisement enabled."
log "---"
log "Tailscale Exit Node is RUNNING."
log "Hostname: ${HOSTNAME}"
log "IP: ${TAILSCALE_IP}"
log "Health endpoint: http://0.0.0.0:${PORT}/health"
log "---"

# ---------------------------------------------------------------------------
# Step 5: Self-healing health monitor loop
# ---------------------------------------------------------------------------
# Periodically checks Tailscale status and reconnects if needed.
# The HTTP health server in the background keeps Render's health checks happy.
while true; do
    if ! tailscale status > /dev/null 2>&1; then
        log "WARNING: Tailscale disconnected. Attempting reconnection..."
        tailscale up \
            --reset \
            --authkey="${TAILSCALE_AUTHKEY}" \
            --hostname="${HOSTNAME}" \
            --advertise-exit-node \
            --accept-routes \
            ${TAILSCALE_EXTRA_ARGS:+"${TAILSCALE_EXTRA_ARGS}"} 2>&1 || true
    fi

    # Log periodic status
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "disconnected")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] HEALTH: OK - ${TS_IP}"

    # Check that health server is still running
    if ! kill -0 "${HEALTH_PID}" 2>/dev/null; then
        log "WARNING: HTTP health server died. Restarting..."
        python3 -u -c "
import http.server, json, os
PORT = int(os.environ.get('PORT', 8080))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'status':'alive'}).encode())
    def log_message(self, fmt, *args): pass
s=http.server.HTTPServer(('0.0.0.0',PORT), H)
s.serve_forever()
" &
        HEALTH_PID=$!
    fi

    sleep 60
done