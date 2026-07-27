#!/usr/bin/env python3
"""Tailscale Exit Node HTTP Health, Status, Speed Test & Proxy Server."""
import http.server, json, os, sys, subprocess, socket, select, urllib.request

PORT = int(os.environ.get('PORT', 8080))

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
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
        elif self.path == '/speedtest.bin':
            self._serve_speedtest_file()
        else:
            self.send(200, b'text/plain',
                b'TAILSCALE EXIT NODE - HEALTH OK\n')

    def do_POST(self):
        if self.path == '/speedtest/upload':
            self._handle_speedtest_upload()

    def do_CONNECT(self):
        try:
            host, port = self.path.split(':')
            port = int(port)
            self.send_response(200)
            self.end_headers()
            dest = socket.create_connection((host, port), timeout=30)
            self.connection.setblocking(True)
            dest.setblocking(True)
            while True:
                r, _, _ = select.select([self.connection, dest], [], [], 30)
                if not r: break
                for s in r:
                    data = s.recv(65536)
                    if not data: return
                    if s is self.connection:
                        dest.sendall(data)
                    else:
                        self.connection.sendall(data)
        except Exception as e:
            try: self.send_error(502, str(e))
            except: pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header('Content-Type', ctype.decode())
        self.end_headers()
        self.wfile.write(body)

    def _proxy_request(self):
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
            try: self.send_error(502, str(e))
            except: pass

    def _get_status(self):
        try:
            r = subprocess.run(['tailscale','status','--json'],
                capture_output=True, text=True, timeout=10)
            return json.loads(r.stdout) if r.returncode == 0 else {}
        except: return {}

    def _get_external_ip(self):
        try:
            return urllib.request.urlopen('https://ifconfig.me', timeout=5).read().decode().strip()
        except: return 'unknown'

    def _test_udp(self):
        import socket as sck
        try:
            sock = sck.socket(sck.AF_INET, sck.SOCK_DGRAM)
            sock.settimeout(3)
            sock.sendto(b'udp-test-from-render-exit', ('65.21.106.102', 8080))
            data, _ = sock.recvfrom(1024)
            sock.close()
            return 'WORKING', data.decode().strip()[:60]
        except sck.timeout:
            return 'BLOCKED', 'No response (timeout)'
        except Exception as e:
            return 'ERROR', str(e)[:60]
        finally:
            try: sock.close()
            except: pass

    def _serve_speedtest_file(self):
        size = 2 * 1024 * 1024
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(size))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        chunk = b'x' * 65536
        sent = 0
        while sent < size:
            self.wfile.write(chunk[:min(65536, size - sent)])
            sent += 65536

    def _handle_speedtest_upload(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 0:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk: break
                remaining -= len(chunk)
            received = length - remaining
        else:
            received = 0
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'received': received}).encode())

    def _build_status_page(self):
        d = self._get_status()
        s = d.get('Self', {}); ps = d.get('Peer', {}); v = d.get('Version', '?')
        ips = d.get('TailscaleIPs', []); mip = ips[0] if ips else '?'
        hn = s.get('HostName', '?')
        sc = 'on' if s.get('Online') else 'off'
        ext_ip = self._get_external_ip()
        udp_st, udp_detail = self._test_udp()
        from datetime import datetime
        ts = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        rows = ''
        rows += '<tr style="border-left:3px solid #3fb950">'
        rows += '<td>' + hn + ' &#11088; <span class=badge-active>ACTIVE</span></td>'
        rows += '<td><code>' + mip + '</code></td>'
        rows += '<td>' + s.get("OS","linux") + '</td>'
        rows += '<td><span style=color:#484f58;font-size:.75rem>direct</span></td>'
        rows += '<td><span class=badge-on>ONLINE</span></td></tr>'

        for p in ps.values():
            n = p.get('DNSName','').rstrip('.').split('.')[0]
            ip = (p.get('TailscaleIPs') or [''])[0]
            e = p.get('ExitNodeOption', False)
            o = p.get('Online', False)
            r = p.get('Relay', '')
            ex_tag = ' <span class=badge-exit>EXIT</span>' if e else ''
            badge = 'on' if o else 'off'
            label = 'ONLINE' if o else 'OFFLINE'
            relay_tag = ' <span class=badge-relay>' + r + '</span>' if r else '<span style=color:#484f58;font-size:.75rem>direct</span>'
            stale = ' <span class=badge-stale>STALE</span>' if (e and n != hn and n.startswith(hn)) else ''
            rows += '<tr><td>' + n + ex_tag + stale + '</td><td><code>' + ip + '</code></td><td>' + p.get("OS","") + '</td><td>' + relay_tag + '</td><td><span class=badge-' + badge + '>' + label + '</span></td></tr>'

        udp_css = 'ok' if udp_st == 'WORKING' else 'blocked'
        dev_count = str(len(ps) + 1)
        online_yes = 'YES' if s.get('Online') else 'NO'
        exit_yn = '\u2705' if s.get('ExitNodeOption') else '\u274c'
        udp_live = '\u25cf LIVE' if s.get('Online') else '\u25cb OFFLINE'

        html = '<!DOCTYPE html><html lang=en><head>'
        html += '<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">'
        html += '<meta http-equiv=refresh content=30>'
        html += '<title>Tailscale Status</title><style>'
        html += '*{margin:0;padding:0;box-sizing:border-box}'
        html += 'body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;line-height:1.6;padding:20px}'
        html += 'h1{font-size:1.5rem;font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:12px}'
        html += '.sub{color:#8b949e;font-size:.85rem;margin-bottom:24px}'
        html += '.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}'
        html += '.card h2{font-size:1rem;font-weight:600;color:#f0f6fc;margin-bottom:12px}'
        html += 'table{width:100%;border-collapse:collapse}'
        html += 'th,td{text-align:left;padding:8px 4px;border-bottom:1px solid #21262d;font-size:.875rem}'
        html += 'th{color:#8b949e;font-weight:500;font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}'
        html += 'td:last-child{text-align:right}'
        html += 'tr:last-child td{border-bottom:none}'
        html += '.badge-on,.badge-off{display:inline-block;padding:2px 10px;border-radius:12px;font-size:.75rem;font-weight:600}'
        html += '.badge-on{background:#003d29;color:#3fb950}'
        html += '.badge-off{background:#3d0027;color:#f85149}'
        html += '.badge-exit{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.7rem;font-weight:600;background:#1f6feb22;color:#58a6ff;margin-left:6px}'
        html += '.badge-relay{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.65rem;font-weight:600;background:#da363322;color:#f78166;margin-left:4px}'
        html += '.badge-active{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.7rem;font-weight:600;background:#003d29;color:#3fb950;margin-left:4px}'
        html += '.badge-stale{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.65rem;font-weight:600;background:#da363322;color:#f78166;margin-left:4px}'
        html += 'code{background:#21262d;padding:2px 6px;border-radius:4px;font-size:.8rem}'
        html += '.grid{display:grid;grid-template-columns:auto 1fr;gap:4px 16px;font-size:.875rem}'
        html += '.grid dt{color:#8b949e}.grid dd{color:#f0f6fc}'
        html += '.udp-ok{color:#3fb950;font-weight:600}'
        html += '.udp-blocked{color:#f85149;font-weight:600}'
        html += '.tip{background:#1f6feb22;border:1px solid #1f6feb;border-radius:8px;padding:12px 16px;margin-bottom:16px;font-size:.875rem}'
        html += '.tip strong{color:#58a6ff}'
        html += '.footer{text-align:center;color:#484f58;font-size:.75rem;margin-top:32px}'
        html += 'a{color:#58a6ff;text-decoration:none}'
        html += '</style></head><body>'
        html += '<h1><span class=badge-' + sc + '>' + udp_live + '</span>' + hn + '</h1>'
        html += '<p class=sub>Tailscale exit node &middot; <a href=/status>refresh</a> &middot; auto-refresh 30s &middot; <a href=/api/status>JSON</a></p>'
        html += '<div class=tip><strong>Connect your Android:</strong> Open Tailscale app &rarr; Exit Node &rarr; select <code>' + hn + '</code> (the ACTIVE one, not STALE)</div>'
        html += '<div class=card><h2>This Node</h2><dl class=grid>'
        html += '<dt>Hostname</dt><dd>' + hn + '</dd>'
        html += '<dt>Tailscale IP</dt><dd><code>' + mip + '</code></dd>'
        html += '<dt>External IP</dt><dd><code>' + ext_ip + '</code></dd>'
        html += '<dt>Version</dt><dd><code>' + v + '</code></dd>'
        html += '<dt>OS</dt><dd>' + s.get('OS','?') + '</dd>'
        html += '<dt>Online</dt><dd><span class=badge-' + sc + '>' + online_yes + '</span></dd>'
        html += '<dt>Offers Exit Node</dt><dd>' + exit_yn + '</dd>'
        html += '</dl></div>'
        html += '<div class=card><h2>UDP Test</h2>'
        html += '<p class=udp-' + udp_css + ' style=font-size:1.1rem>' + ('WORKING' if udp_st == 'WORKING' else udp_st) + '</p>'
        html += '<p class=sub style=margin-top:4px>Echo server 65.21.106.102:8080 &middot; ' + udp_detail + '</p></div>'
        html += '<div class=card><h2>Speed Test (browser to this node)</h2>'
        html += '<div id=speedtest-results><p class=sub>Click <button onclick="runSpeedTest()" style="background:#1f6feb;border:none;color:#fff;padding:4px 12px;border-radius:6px;cursor:pointer">Run Test</button> to measure download &amp; upload speed</p></div>'
        html += '<p class=sub style=margin-top:8px>Downloads 2MB, uploads 1MB to this node</p></div>'
        html += '<script>'
        html += 'function runSpeedTest(){'
        html += 'var r=document.getElementById("speedtest-results");'
        html += 'r.innerHTML="<p class=sub>Testing download...</p>";'
        html += 'var t0=performance.now();'
        html += 'var x=new XMLHttpRequest();'
        html += 'x.open("GET","/speedtest.bin",true);'
        html += 'x.responseType="arraybuffer";'
        html += 'x.onprogress=function(e){if(e.lengthComputable){'
        html += 'var pct=Math.round(e.loaded/e.total*100);'
        html += 'r.innerHTML="<p class=sub>Downloading... "+pct+"%</p>"'
        html += '}};'
        html += 'x.onload=function(){'
        html += 'var dt=(performance.now()-t0)/1000;'
        html += 'var total=x.response.byteLength;'
        html += 'var dlMbps=((total*8)/dt/1e6).toFixed(1);'
        html += 'r.innerHTML="<p style=color:#3fb950;font-weight:600>Download: "+dlMbps+" Mbps</p>"'
        html += '+"<p class=sub>"+(total/1e6).toFixed(1)+"MB in "+dt.toFixed(1)+"s</p>"'
        html += '+"<p class=sub>Testing upload...</p>";'
        html += 'var t1=performance.now();'
        html += 'var upData=new Uint8Array(1*1024*1024);'
        html += 'var upX=new XMLHttpRequest();'
        html += 'upX.open("POST","/speedtest/upload",true);'
        html += 'upX.setRequestHeader("Content-Type","application/octet-stream");'
        html += 'upX.onload=function(){'
        html += 'var ut=(performance.now()-t1)/1000;'
        html += 'var upJson=JSON.parse(upX.responseText);'
        html += 'var ulMbps=((upJson.received*8)/ut/1e6).toFixed(1);'
        html += 'r.innerHTML="<p style=color:#3fb950;font-weight:600>Download: "+dlMbps+" Mbps</p>"'
        html += '+"<p style=color:#58a6ff;font-weight:600>Upload: "+ulMbps+" Mbps</p>"'
        html += '+"<p class=sub>"+(upJson.received/1e6).toFixed(1)+"MB in "+ut.toFixed(1)+"s</p>"'
        html += '+"<p class=sub><button onclick=runSpeedTest() style=background:#21262d;border:1px solid #30363d;color:#c9d1d9;padding:4px 12px;border-radius:6px;cursor:pointer>Test again</button></p>"'
        html += '};'
        html += 'upX.send(upData)'
        html += '};'
        html += 'x.send()}'
        html += '</script>'
        html += '<div class=card><h2>All Devices (' + dev_count + ')</h2>'
        html += '<table><thead><tr><th>Device</th><th>Tailscale IP</th><th>OS</th><th>Relay</th><th>Status</th></tr></thead>'
        html += '<tbody>' + rows + '</tbody></table></div>'
        html += '<div class=footer>' + v + ' &middot; ' + mip + ' &middot; ' + ts + '</div>'
        html += '</body></html>'
        return html

    def _build_json_status(self):
        d = self._get_status()
        si = d.get('Self',{}); ps = d.get('Peer',{})
        devs = [{'name':p.get('DNSName','').split('.')[0],'ip':(p.get('TailscaleIPs') or [None])[0],'os':p.get('OS',''),'online':p.get('Online',False),'relay':p.get('Relay','direct')} for p in ps.values()]
        return {'this_node':{'name':si.get('HostName',''),'ip':d.get('TailscaleIPs',[]),'version':d.get('Version','')},'connected_devices':devs,'total':len(devs)}

    def log_message(self, fmt, *args): pass

s = http.server.HTTPServer(('0.0.0.0', PORT), H)
sys.stdout.write('[HEALTH] HTTP server listening on port ' + str(PORT) + '\n')
sys.stdout.flush()
s.serve_forever()