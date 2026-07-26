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
HOSTNAME="${HOSTNAME:-renderfn-exit}"
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
        elif self.path == '/status':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            try:
                import subprocess
                r = subprocess.run(['tailscale', 'status', '--json'], capture_output=True, text=True, timeout=10)
                d = json.loads(r.stdout) if r.returncode == 0 else {}
            except: d = {}
            self_info = d.get('Self', {})
            peers = d.get('Peer', {})
            ver = d.get('Version', 'unknown')
            ts_ips = d.get('TailscaleIPs', [])
            rows = ''
            for pid, p in peers.items():
                nm = p.get('DNSName','').rstrip('.').split('.')[0]
                ip = (p.get('TailscaleIPs') or [''])[0]
                os_ = p.get('OS','')
                on = p.get('Online',False)
                ex = p.get('ExitNodeOption',False)
                badge_cls = 'on' if on else 'off'
                ex_badge = ' <span class=badge-exit>EXIT</span>' if ex else ''
                rows += f'<tr><td>{nm}{ex_badge}</td><td><code>{ip}</code></td><td>{os_}</td><td><span class=badge-{badge_cls}>{"ONLINE" if on else "OFFLINE"}</span></td></tr>'
            my_ip = ts_ips[0] if ts_ips else '?'
            status_cls = 'on' if self_info.get('Online') else 'off'
            self.wfile.write(f'''<!DOCTYPE html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=30>
<title>Tailscale Status – {self_info.get("HostName","?")}</title>
<style>
*,:after,:before{{box-sizing:border-box;margin:0;padding:0}}
body{{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;line-height:1.6;padding:20px}}
h1{{font-size:1.5rem;font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:12px}}
.sub{{color:#8b949e;font-size:.85rem;margin-bottom:24px}}
.card{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}}
.card h2{{font-size:1rem;font-weight:600;color:#f0f6fc;margin-bottom:12px}}
table{{width:100%;border-collapse:collapse}}
th,td{{text-align:left;padding:8px 4px;border-bottom:1px solid #21262d;font-size:.875rem}}
th{{color:#8b949e;font-weight:500;font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}}
td:last-child{{text-align:right}}
tr:last-child td{{border-bottom:none}}
.badge-on,.badge-off{{display:inline-block;padding:2px 10px;border-radius:12px;font-size:.75rem;font-weight:600}}
.badge-on{{background:#003d29;color:#3fb950}}
.badge-off{{background:#3d0027;color:#f85149}}
.badge-exit{{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.7rem;font-weight:600;background:#1f6feb22;color:#58a6ff;margin-left:6px}}
code{{background:#21262d;padding:2px 6px;border-radius:4px;font-size:.8rem}}
.grid{{display:grid;grid-template-columns:auto 1fr;gap:4px 16px;font-size:.875rem}}
.grid dt{{color:#8b949e}}
.grid dd{{color:#f0f6fc}}
.footer{{text-align:center;color:#484f58;font-size:.75rem;margin-top:32px}}
a{{color:#58a6ff;text-decoration:none}}
</style></head><body>
<h1><span class=badge-{status_cls}>{"● LIVE" if self_info.get("Online") else "○ OFFLINE"}</span>{self_info.get("HostName","?")}</h1>
<p class=sub>Tailscale exit node · <a href=/status>refresh</a> · auto-refreshes every 30s</p>
<div class=card>
<h2>This Node</h2>
<dl class=grid>
<dt>Hostname</dt><dd>{self_info.get("HostName","?")}</dd>
<dt>IPv4</dt><dd><code>{my_ip}</code></dd>
<dt>IPv6</dt><dd><code>{ts_ips[1] if len(ts_ips)>1 else '—'}</code></dd>
<dt>Version</dt><dd><code>{ver}</code></dd>
<dt>OS</dt><dd>{self_info.get("OS","?")}</dd>
<dt>Online</dt><dd><span class=badge-{status_cls}>{"YES" if self_info.get("Online") else "NO"}</span></dd>
<dt>Offers Exit Node</dt><dd>{"✅" if self_info.get("ExitNodeOption") else "❌"}</dd>
</dl>
</div>
<div class=card>
<h2>Connected Devices ({len(peers)})</h2>
<table><thead><tr><th>Device</th><th>Tailscale IP</th><th>OS</th><th>Status</th></tr></thead>
<tbody>{rows}</tbody></table>
</div>
<div class=footer>renderfn-exit · {ver} · {my_ip}</div>
</body></html>'''.encode())
        elif self.path == '/api/status':
            # JSON status for programmatic access
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            try:
                import subprocess
                r = subprocess.run(['tailscale', 'status', '--json'], capture_output=True, text=True, timeout=10)
                if r.returncode == 0:
                    data = json.loads(r.stdout)
                    si = data.get('Self',{})
                    peers = data.get('Peer',{})
                    devices = [{'name':p.get('DNSName','').split('.')[0],'ip':(p.get('TailscaleIPs') or [None])[0],'os':p.get('OS',''),'online':p.get('Online',False)} for p in peers.values()]
                    self.wfile.write(json.dumps({'this_node':{'name':si.get('HostName',''),'ip':data.get('TailscaleIPs',[]),'version':data.get('Version','')},'connected_devices':devices,'total':len(devices)},indent=2).encode())
                else:
                    self.wfile.write(json.dumps({'error':'status failed'}).encode())
            except Exception as e:
                self.wfile.write(json.dumps({'error':str(e)}).encode())
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
import http.server, json, os, sys, subprocess
PORT = int(os.environ.get('PORT', 8080))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({'status':'alive','service':'tailscale-exit-node'}).encode())
        elif self.path == '/status':
            self.send_response(200); self.send_header('Content-Type','text/html;charset=utf-8'); self.end_headers()
            try:
                import subprocess
                r = subprocess.run(['tailscale','status','--json'],capture_output=True,text=True,timeout=10)
                d = json.loads(r.stdout) if r.returncode==0 else {}
            except: d={}
            s=d.get('Self',{}); ps=d.get('Peer',{}); v=d.get('Version','?'); ips=d.get('TailscaleIPs',[])
            rws=''
            for p in ps.values():
                n=p.get('DNSName','').rstrip('.').split('.')[0]; ip=(p.get('TailscaleIPs') or [''])[0]
                e=p.get('ExitNodeOption',False); o=p.get('Online',False)
                rws+=f'<tr><td>{n}{" <span class=badge-exit>EXIT</span>" if e else ""}</td><td><code>{ip}</code></td><td>{p.get("OS","")}</td><td><span class=badge-{"on" if o else "off"}>{("ONLINE" if o else "OFFLINE")}</span></td></tr>'
            mip=ips[0] if ips else '?'; sc='on' if s.get('Online') else 'off'
            self.wfile.write(f'''<!DOCTYPE html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta http-equiv=refresh content=30><title>Tailscale Status</title><style>*{{margin:0;padding:0;box-sizing:border-box}}body{{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;line-height:1.6;padding:20px}}h1{{font-size:1.5rem;font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:12px}}.sub{{color:#8b949e;font-size:.85rem;margin-bottom:24px}}.card{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}}.card h2{{font-size:1rem;font-weight:600;color:#f0f6fc;margin-bottom:12px}}table{{width:100%;border-collapse:collapse}}th,td{{text-align:left;padding:8px 4px;border-bottom:1px solid #21262d;font-size:.875rem}}th{{color:#8b949e;font-weight:500;font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}}td:last-child{{text-align:right}}tr:last-child td{{border-bottom:none}}.badge-on,.badge-off{{display:inline-block;padding:2px 10px;border-radius:12px;font-size:.75rem;font-weight:600}}.badge-on{{background:#003d29;color:#3fb950}}.badge-off{{background:#3d0027;color:#f85149}}.badge-exit{{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.7rem;font-weight:600;background:#1f6feb22;color:#58a6ff;margin-left:6px}}code{{background:#21262d;padding:2px 6px;border-radius:4px;font-size:.8rem}}.grid{{display:grid;grid-template-columns:auto 1fr;gap:4px 16px;font-size:.875rem}}.grid dt{{color:#8b949e}}.grid dd{{color:#f0f6fc}}.footer{{text-align:center;color:#484f58;font-size:.75rem;margin-top:32px}}a{{color:#58a6ff}}}</style></head><body><h1><span class=badge-{sc}>{"● LIVE" if s.get("Online") else "○ OFFLINE"}</span>{s.get("HostName","?")}</h1><p class=sub>Tailscale exit node · auto-refresh 30s</p><div class=card><h2>This Node</h2><dl class=grid><dt>Hostname</dt><dd>{s.get("HostName","?")}</dd><dt>IPv4</dt><dd><code>{mip}</code></dd><dt>Version</dt><dd><code>{v}</code></dd><dt>Online</dt><dd><span class=badge-{sc}>{"YES" if s.get("Online") else "NO"}</span></dd><dt>Offers Exit</dt><dd>{"✅" if s.get("ExitNodeOption") else "❌"}</dd></dl></div><div class=card><h2>Devices ({len(ps)})</h2><table><thead><tr><th>Device</th><th>IP</th><th>OS</th><th>Status</th></tr></thead><tbody>{rws}</tbody></table></div><div class=footer>{v} · {mip}</div></body></html>'''.encode())
        elif self.path == '/api/status':
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            try:
                r = subprocess.run(['tailscale','status','--json'],capture_output=True,text=True,timeout=10)
                if r.returncode==0:
                    d=json.loads(r.stdout); si=d.get('Self',{}); ps=d.get('Peer',{})
                    devs=[{'name':p.get('DNSName','').split('.')[0],'ip':(p.get('TailscaleIPs') or [None])[0],'os':p.get('OS',''),'online':p.get('Online',False)} for p in ps.values()]
                    self.wfile.write(json.dumps({'this_node':{'name':si.get('HostName',''),'ip':d.get('TailscaleIPs',[]),'version':d.get('Version','')},'connected_devices':devs,'total':len(devs)},indent=2).encode())
                else:
                    self.wfile.write(json.dumps({'error':'status failed'}).encode())
            except Exception as e:
                self.wfile.write(json.dumps({'error':str(e)}).encode())
        else:
            self.send_response(200); self.send_header('Content-Type','text/plain'); self.end_headers()
            self.wfile.write(b'TAILSCALE EXIT NODE - HEALTH OK\n')
    def log_message(self, fmt, *args): pass
s=http.server.HTTPServer(('0.0.0.0',PORT), H)
s.serve_forever()
" &
        HEALTH_PID=$!
    fi

    sleep 60
done