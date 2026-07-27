#!/usr/bin/env python3
"""Tailscale Exit Node HTTP Health & Status Server."""
import http.server, json, os, sys, subprocess

PORT = int(os.environ.get('PORT', 8080))

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # HTTP forward proxy mode: if path is a full URL, fetch and return
        if self.path.startswith('http://') or self.path.startswith('https://'):
            self._proxy_request()
        elif self.path == '/health':
            self.send(200, b'application/json',
                json.dumps({'status':'alive','service':'tailscale-exit-node'}).encode())
        elif self.path == '/status':
            html = self._build_status_page()
            self.send(200, b'text/html;charset=utf-8', html.encode())
        elif self.path == '/api/status':
            self.send(200, b'application/json',
                json.dumps(self._build_json_status(), indent=2).encode())
        else:
            self.send(200, b'text/plain',
                b'TAILSCALE EXIT NODE - HEALTH OK\n')

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header('Content-Type', ctype.decode())
        self.end_headers()
        self.wfile.write(body)

    def _proxy_request(self):
        """HTTP forward proxy: fetch a URL and return its content.
        Set Android WiFi proxy to: tailscale-exit-node-9bxt.onrender.com:443
        """
        import urllib.request
        try:
            req = urllib.request.Request(self.path,
                headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ('content-type', 'content-length', 'cache-control'):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)
        except Exception as e:
            try:
                self.send_error(502, str(e))
            except: pass

    def _get_status(self):
        try:
            r = subprocess.run(['tailscale','status','--json'],
                capture_output=True, text=True, timeout=10)
            return json.loads(r.stdout) if r.returncode == 0 else {}
        except: return {}

    def _get_external_ip(self):
        """Get the public IP of this exit node."""
        try:
            import urllib.request
            ip = urllib.request.urlopen('https://ifconfig.me', timeout=5).read().decode().strip()
            return ip
        except: return 'unknown'

    def _test_udp(self):
        """Test UDP connectivity to echo server."""
        import socket
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(3)
            sock.sendto(b'udp-test-from-render-exit', ('65.21.106.102', 8080))
            data, _ = sock.recvfrom(1024)
            sock.close()
            return '✅ WORKING', data.decode().strip()[:60], '#3fb950'
        except socket.timeout:
            return '❌ BLOCKED', 'No response (timeout)', '#f85149'
        except Exception as e:
            return '❌ ERROR', str(e)[:60], '#f85149'
        finally:
            try: sock.close()
            except: pass

    def _build_status_page(self):
        d = self._get_status()
        s = d.get('Self', {}); ps = d.get('Peer', {}); v = d.get('Version', '?')
        ips = d.get('TailscaleIPs', []); mip = ips[0] if ips else '?'
        hn = s.get('HostName', '?')
        sc = 'on' if s.get('Online') else 'off'
        ext_ip = self._get_external_ip()
        udp_st, udp_detail, udp_color = self._test_udp()
        from datetime import datetime
        ts = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        # Build device rows — include Self first as ACTIVE
        rows = ''
        # Self (the current node, always first)
        rows += '<tr style="border-left:3px solid #3fb950">'
        rows += f'<td>{hn} ⭐ <span class=badge-active>ACTIVE</span></td>'
        rows += f'<td><code>{mip}</code></td>'
        rows += f'<td>{s.get("OS","linux")}</td>'
        rows += '<td><span style=color:#484f58;font-size:.75rem>direct</span></td>'
        rows += f'<td><span class=badge-on>ONLINE</span></td></tr>'

        # Peers
        for p in ps.values():
            n = p.get('DNSName','').rstrip('.').split('.')[0]
            ip = (p.get('TailscaleIPs') or [''])[0]
            e = p.get('ExitNodeOption', False)
            o = p.get('Online', False)
            r = p.get('Relay', '')
            ex_tag = ' <span class=badge-exit>EXIT</span>' if e else ''
            badge = 'on' if o else 'off'
            label = 'ONLINE' if o else 'OFFLINE'
            relay_tag = f' <span class=badge-relay>{r}</span>' if r else '<span style=color:#484f58;font-size:.75rem>direct</span>'
            # Mark stale exit nodes (have suffix like -1, -2 while current has no suffix)
            stale_tag = ''
            if e and n != hn and (n.startswith(hn) and n != hn):
                stale_tag = ' <span class=badge-stale>STALE</span>'
            rows += f'<tr><td>{n}{ex_tag}{stale_tag}</td><td><code>{ip}</code></td><td>{p.get("OS","")}</td><td>{relay_tag}</td><td><span class=badge-{badge}>{label}</span></td></tr>'

        return f'''<!DOCTYPE html><html lang=en><head>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=30>
<title>Tailscale Status</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
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
.badge-relay{{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.65rem;font-weight:600;background:#da363322;color:#f78166;margin-left:4px}}
.badge-active{{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.7rem;font-weight:600;background:#003d29;color:#3fb950;margin-left:4px}}
.badge-stale{{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.65rem;font-weight:600;background:#da363322;color:#f78166;margin-left:4px}}
code{{background:#21262d;padding:2px 6px;border-radius:4px;font-size:.8rem}}
.grid{{display:grid;grid-template-columns:auto 1fr;gap:4px 16px;font-size:.875rem}}
.grid dt{{color:#8b949e}}.grid dd{{color:#f0f6fc}}
.udp-ok{{color:#3fb950;font-weight:600}}
.udp-blocked{{color:#f85149;font-weight:600}}
.tip{{background:#1f6feb22;border:1px solid #1f6feb;border-radius:8px;padding:12px 16px;margin-bottom:16px;font-size:.875rem}}
.tip strong{{color:#58a6ff}}
.footer{{text-align:center;color:#484f58;font-size:.75rem;margin-top:32px}}
a{{color:#58a6ff;text-decoration:none}}
</style></head><body>
<h1><span class=badge-{sc}>{"● LIVE" if s.get("Online") else "○ OFFLINE"}</span>{hn}</h1>
<p class=sub>Tailscale exit node &middot; <a href=/status>refresh</a> &middot; auto-refresh 30s &middot; <a href=/api/status>JSON</a></p>
<div class=tip>
<strong>📱 Connect your Android:</strong> Open Tailscale app → Exit Node → select <code>{hn}</code> (the ACTIVE one, not STALE)
</div>
<div class=card><h2>This Node</h2><dl class=grid>
<dt>Hostname</dt><dd>{hn}</dd>
<dt>Tailscale IP</dt><dd><code>{mip}</code></dd>
<dt>External IP</dt><dd><code>{ext_ip}</code></dd>
<dt>Version</dt><dd><code>{v}</code></dd>
<dt>OS</dt><dd>{s.get("OS","?")}</dd>
<dt>Online</dt><dd><span class=badge-{sc}>{"YES" if s.get("Online") else "NO"}</span></dd>
<dt>Offers Exit Node</dt><dd>{"✅" if s.get("ExitNodeOption") else "❌"}</dd>
</dl></div>
<div class=card><h2>🔌 UDP Test</h2>
<p class=udp-{"ok" if "WORKING" in udp_st else "blocked"} style=font-size:1.1rem>{udp_st}</p>
<p class=sub style=margin-top:4px>Echo server 65.21.106.102:8080 &middot; {udp_detail}</p>
</div>
<div class=card><h2>All Devices ({len(ps) + 1})</h2>
<table><thead><tr><th>Device</th><th>Tailscale IP</th><th>OS</th><th>Relay</th><th>Status</th></tr></thead>
<tbody>{rows}</tbody></table></div>
<div class=footer>{v} &middot; {mip} &middot; {ts}</div>
</body></html>'''

    def _build_json_status(self):
        d = self._get_status()
        si = d.get('Self',{}); ps = d.get('Peer',{})
        devs = [{'name':p.get('DNSName','').split('.')[0],'ip':(p.get('TailscaleIPs') or [None])[0],'os':p.get('OS',''),'online':p.get('Online',False),'relay':p.get('Relay','direct')} for p in ps.values()]
        return {'this_node':{'name':si.get('HostName',''),'ip':d.get('TailscaleIPs',[]),'version':d.get('Version','')},'connected_devices':devs,'total':len(devs)}

    def log_message(self, fmt, *args): pass

s = http.server.HTTPServer(('0.0.0.0', PORT), H)
sys.stdout.write(f'[HEALTH] HTTP server listening on port {PORT}\n')
sys.stdout.flush()
s.serve_forever()