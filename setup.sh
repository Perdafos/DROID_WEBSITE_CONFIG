#!/bin/bash
# ============================================================
# DroidCam Relay — All-in-One VPS Setup Script
# ============================================================
# Jalankan sebagai root: bash setup.sh
# ============================================================
set -e

DOMAIN="${1:-doridcam.perdafos.my.id}"
RELAY_PORT=3000
NODE_VERSION=20

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║     DroidCam Relay — VPS Auto Setup          ║"
echo "║───────────────────────────────────────────────║"
echo "║  Domain  : $DOMAIN"
echo "║  Port    : $RELAY_PORT"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# ── Cek root ────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "! Jalankan sebagai root: bash setup.sh"
  exit 1
fi

# ── 1. Update system ────────────────────────────────────────
echo "[1/8] Update system packages..."
apt update && apt upgrade -y

# ── 2. Install Node.js ──────────────────────────────────────
echo "[2/8] Install Node.js $NODE_VERSION..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
  apt install -y nodejs
fi
echo "  Node: $(node -v)"
echo "  npm:  $(npm -v)"

# ── 3. Install Nginx + Certbot ──────────────────────────────
echo "[3/8] Install Nginx & Certbot..."
apt install -y nginx certbot python3-certbot-nginx

# ── 3b. Install FFmpeg (needed for RTSP) ───────────────────
echo "[3b/8] Install FFmpeg..."
if ! command -v ffmpeg &>/dev/null; then
  apt install -y ffmpeg
fi
echo "  FFmpeg: $(ffmpeg -version 2>&1 | head -1)"

# ── 4. Setup project directory ──────────────────────────────
echo "[4/8] Setup project..."
mkdir -p /opt/droidcam-relay
cd /opt/droidcam-relay

# Create package.json
cat > package.json <<'PKGJSON'
{
  "name": "droidcam-web-relay",
  "version": "1.0.0",
  "description": "Relay DroidCam stream to web viewers",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "dotenv": "^16.4.7",
    "express": "^4.21.2",
    "ws": "^8.18.0"
  }
}
PKGJSON

npm install --production

# ── 5. Create .env ──────────────────────────────────────────
echo "[5/8] Create .env..."
cat > .env <<ENVFILE
# ── Stream type ──────────────────────────────────
# "http" — DroidCam HTTP MJPEG (default, bisa pairing)
# "rtsp" — RTSP camera via FFmpeg
STREAM_TYPE=http

# ── HTTP source (DroidCam) ───────────────────────
# Diisi otomatis via pairing page
DROIDCAM_URL=http://192.168.1.100:4747/video

# ── RTSP source (camera IP/NVR) ─────────────────
# Pakai ini kalau STREAM_TYPE=rtsp
# RTSP_URL=rtsp://user:pass@192.168.1.200:554/stream1
# RTSP_TRANSPORT=tcp
# RTSP_FPS=15
# RTSP_SIZE=640x480
# RTSP_QUALITY=3

# Server config
PORT=$RELAY_PORT
HOST=0.0.0.0
RELAY_MODE=proxy
ENVFILE

# ── 6. Create server.js (with RTSP support) ──────────────
echo "[6/8] Create server.js (RTSP-ready)..."
cat > server.js <<'SRVEOF'
require('dotenv').config();
const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');

// ── Config ──────────────────────────────────────────────────────────────────
const PORT          = process.env.PORT          || 3000;
const HOST          = process.env.HOST          || '0.0.0.0';
const STREAM_TYPE   = process.env.STREAM_TYPE   || 'http';
const DROIDCAM_URL  = process.env.DROIDCAM_URL  || 'http://192.168.1.100:4747/video';
const RTSP_URL      = process.env.RTSP_URL      || '';
const PAIRED_IP_FILE = path.join(__dirname, '.paired_ip');

let sourceUrl = STREAM_TYPE === 'rtsp' ? RTSP_URL : DROIDCAM_URL;

if (STREAM_TYPE !== 'rtsp' && fs.existsSync(PAIRED_IP_FILE)) {
  const saved = fs.readFileSync(PAIRED_IP_FILE, 'utf-8').trim();
  if (saved) { sourceUrl = 'http://' + saved + ':4747/video'; console.log('  Paired IP restored:', saved); }
}

// ── App ─────────────────────────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

app.use((req, res, next) => { res.setHeader('Access-Control-Allow-Origin', '*'); next(); });
app.use(express.json());

// ════════════════════════════════════════════════════════════════════════════
//  StreamBroadcaster — single pipeline shared by all viewers
// ════════════════════════════════════════════════════════════════════════════
class StreamBroadcaster {
  constructor() {
    this.clients = new Set();
    this.mjpegRes = null;
    this._ffmpeg = null;
    this._fetchAbort = null;
    this._buf = null;
    this._rtspBuf = null;
    this._running = false;
    this._restartTimer = null;
    this._boundary = '--jpgboundary';
  }

  get url() { return sourceUrl; }

  refresh() {
    const active = this.clients.size > 0 || this.mjpegRes !== null;
    if (active && !this._running) { this.start(); }
    else if (!active && this._running) { this.stop(); }
  }

  async start() {
    if (this._running) return;
    this._running = true;
    this._buf = Buffer.alloc(0);
    this._rtspBuf = Buffer.alloc(0);
    console.log('[broadcaster] Start (' + STREAM_TYPE + '): ' + sourceUrl);
    try {
      if (STREAM_TYPE === 'rtsp') { this._startRtsp(); }
      else { await this._startHttp(); }
    } catch (err) { console.error('[broadcaster] Error:', err.message); this._scheduleRestart(); }
  }

  stop() {
    this._running = false;
    clearTimeout(this._restartTimer); this._restartTimer = null;
    if (this._ffmpeg) { try { this._ffmpeg.kill('SIGTERM'); } catch (e) {} this._ffmpeg = null; }
    if (this._fetchAbort) { try { this._fetchAbort.abort(); } catch (e) {} this._fetchAbort = null; }
    console.log('[broadcaster] Stopped');
  }

  // ── HTTP source (DroidCam MJPEG) ──────────────────────────────────────────
  async _startHttp() {
    this._fetchAbort = new AbortController();
    const resp = await fetch(sourceUrl, { signal: this._fetchAbort.signal });
    if (!resp.ok) throw new Error('DroidCam HTTP ' + resp.status);
    const ct = resp.headers.get('content-type') || '';
    const m = ct.match(/boundary=(\S+)/);
    this._boundary = m ? m[1] : '--jpgboundary';
    const bDelim = Buffer.from('--' + this._boundary);
    const bHead = Buffer.from('\r\nContent-Type: image/jpeg');
    const bCrlf = Buffer.from('\r\n\r\n');
    const reader = resp.body.getReader();
    while (this._running) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!this._running) return;
      this._buf = Buffer.concat([this._buf, value]);
      this._procHttp(bDelim, bHead, bCrlf);
    }
    if (this._running) this._scheduleRestart();
  }

  _procHttp(bDelim, bHead, bCrlf) {
    let pos = 0;
    while (pos < this._buf.length) {
      const bi = this._buf.indexOf(bDelim, pos); if (bi === -1) break;
      const hi = this._buf.indexOf(bHead, bi + bDelim.length); if (hi === -1) break;
      const di = this._buf.indexOf(bCrlf, hi + bHead.length); if (di === -1) break;
      const fstart = di + bCrlf.length;
      const ni = this._buf.indexOf(bDelim, fstart);
      const flen = ni !== -1 ? ni - fstart - 2 : this._buf.length - fstart;
      if (flen > 0) this._broadcast(this._buf.slice(fstart, fstart + flen));
      if (ni === -1) break;
      pos = ni;
    }
    if (pos > 0) this._buf = this._buf.slice(pos);
  }

  // ── RTSP source (FFmpeg pipe) ─────────────────────────────────────────────
  _startRtsp() {
    if (!RTSP_URL) { console.error('[rtsp] RTSP_URL not set'); this._broadcastError('RTSP_URL not configured'); return; }
    const t = process.env.RTSP_TRANSPORT || 'tcp';
    this._ffmpeg = spawn(process.env.FFMPEG_PATH || 'ffmpeg', [
      '-rtsp_transport', t, '-i', RTSP_URL,
      '-f', 'image2pipe', '-vcodec', 'mjpeg',
      '-q:v', process.env.RTSP_QUALITY || '3',
      '-s', process.env.RTSP_SIZE || '640x480',
      '-r', process.env.RTSP_FPS || '15',
      '-an', 'pipe:1'
    ], { stdio: ['ignore', 'pipe', 'pipe'] });

    this._ffmpeg.stderr.on('data', (d) => {
      const m = d.toString();
      if (/error|failed|cannot/i.test(m)) console.error('[rtsp]', m.trim());
    });
    this._ffmpeg.stdout.on('data', (chunk) => {
      if (!this._running) return;
      this._rtspBuf = Buffer.concat([this._rtspBuf, chunk]);
      this._procRtsp();
    });
    this._ffmpeg.on('error', (err) => { console.error('[rtsp] FFmpeg:', err.message); this._broadcastError('FFmpeg: ' + err.message); if (this._running) this._scheduleRestart(); });
    this._ffmpeg.on('exit', (code, sig) => { console.log('[rtsp] FFmpeg exit (code=' + code + ')'); this._ffmpeg = null; if (this._running) this._scheduleRestart(); });
  }

  _procRtsp() {
    let i = 0;
    while (i < this._rtspBuf.length - 1) {
      if (this._rtspBuf[i] === 0xFF && this._rtspBuf[i+1] === 0xD8) {
        let j = i + 2;
        while (j < this._rtspBuf.length - 1) {
          if (this._rtspBuf[j] === 0xFF && this._rtspBuf[j+1] === 0xD9) {
            this._broadcast(this._rtspBuf.slice(i, j + 2));
            i = j + 2; break;
          }
          j++;
        }
        if (j >= this._rtspBuf.length - 1) break;
      } else { i++; }
    }
    if (i > 0) this._rtspBuf = this._rtspBuf.slice(i);
  }

  // ── Broadcast ─────────────────────────────────────────────────────────────
  _broadcast(frame) {
    for (const ws of this.clients) {
      if (ws.readyState === 1) { try { ws.send(frame, { binary: true }); } catch (e) {} }
    }
    if (this.mjpegRes) {
      try {
        this.mjpegRes.write('--' + this._boundary + '\r\n');
        this.mjpegRes.write('Content-Type: image/jpeg\r\nContent-Length: ' + frame.length + '\r\n\r\n');
        this.mjpegRes.write(frame);
      } catch (e) { this.mjpegRes = null; this.refresh(); }
    }
  }

  _broadcastError(msg) {
    const j = JSON.stringify({ error: msg });
    for (const ws of this.clients) { if (ws.readyState === 1) { try { ws.send(j); } catch (e) {} } }
  }

  _scheduleRestart() {
    if (!this._running) return;
    clearTimeout(this._restartTimer);
    this._restartTimer = setTimeout(() => {
      if (!this._running) return;
      if (this.clients.size === 0 && !this.mjpegRes) { this.stop(); return; }
      console.log('[broadcaster] Restarting...');
      this.stop(); this.start();
    }, 3000);
  }
}

const broadcaster = new StreamBroadcaster();

// ════════════════════════════════════════════════════════════════════════════
//  Routes
// ════════════════════════════════════════════════════════════════════════════

app.get('/status', (req, res) => {
  res.json({
    uptime: process.uptime(),
    streamType: STREAM_TYPE,
    source: sourceUrl,
    viewers: broadcaster.clients.size,
    paired: STREAM_TYPE !== 'rtsp' && fs.existsSync(PAIRED_IP_FILE),
  });
});

app.get('/pair', (req, res) => {
  if (STREAM_TYPE === 'rtsp') {
    return res.send('<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>RTSP Mode</title><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;min-height:100vh}.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:2.5rem;max-width:520px;width:90%;text-align:center}.badge{display:inline-block;padding:.3rem 1rem;border-radius:999px;background:#1f2e17;border:1px solid #3b6e1f;color:#b1e58b;margin:1rem 0}.info{text-align:left;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:1rem;font-size:.85rem;color:#8b949e;margin-top:1rem}code{color:#c9d1d9;background:#21262d;padding:.15rem .5rem;border-radius:4px}</style></head><body><div class="card"><h1>RTSP Mode</h1><div class="badge">RTSP Active</div><p>Pairing tdk tersedia di mode RTSP.</p><div class="info">URL RTSP: <code>' + (RTSP_URL || '(not set)') + '</code><br><br>Ubah di <code>.env</code>:<br><code>STREAM_TYPE=rtsp</code><br><code>RTSP_URL=rtsp://user:pass@ip:554/...</code></div></div></body></html>');
  }
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  const isPaired = fs.existsSync(PAIRED_IP_FILE);
  res.send('<!DOCTYPE html><html lang="id"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Pairing</title><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;min-height:100vh}.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:2.5rem;max-width:480px;width:90%;text-align:center;box-shadow:0 8px 24px rgba(0,0,0,.4)}h1{font-size:1.5rem}p{color:#8b949e;font-size:.95rem}.badge{display:inline-block;padding:.3rem 1rem;border-radius:999px;font-size:.85rem;margin-bottom:1.5rem}.badge-paired{background:#0f3a1e;border:1px solid #238636;color:#7ee787}.badge-unpaired{background:#3a0f0f;border:1px solid #863023;color:#ff7b72}.ip-box{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:.75rem;font-family:monospace;font-size:1.2rem;margin:1rem 0}.btn{display:inline-flex;align-items:center;gap:.5rem;padding:.75rem 2rem;border-radius:8px;border:none;font-size:1rem;cursor:pointer;transition:opacity .15s}.btn-primary{background:#238636;color:#fff}.btn-primary:disabled{opacity:.5;cursor:not-allowed}.btn-danger{background:#da3633;color:#fff;margin-top:.75rem}.info{font-size:.8rem;color:#484f58;margin-top:1.5rem}.error{color:#ff7b72}.success{color:#7ee787}.spin{display:inline-block;width:16px;height:16px;border:2px solid #fff;border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}</style></head><body><div class="card"><h1>DroidCam Pairing</h1><p>Daftarkan laptop ini sbg sumber kamera</p><div id="badge" class="badge ' + (isPaired ? 'badge-paired">Terdaftar' : 'badge-unpaired">Belum terdaftar') + '</div><p style="color:#8b949e;font-size:.85rem">IP terdeteksi:</p><div class="ip-box" id="myIp">' + ip + '</div><div id="statusMsg"></div><button id="btnPair" class="btn btn-primary"' + (isPaired ? ' disabled' : '') + '>' + (isPaired ? 'Sudah terdaftar' : 'Daftarkan laptop ini') + '</button>' + (isPaired ? '<br><button id="btnUnpair" class="btn btn-danger">Lepas daftar</button>' : '') + '<div class="info"><strong>Syarat:</strong><br>1. Laptop sumber install DroidCam (mode WiFi)<br>2. Laptop & VPS harus terhubung<br>3. Port 4747 terbuka</div></div><script>document.getElementById("btnPair")?.addEventListener("click",async function(){this.disabled=true;this.innerHTML="<span class=spin></span> Mendaftarkan...";try{const r=await fetch("/api/pair",{method:"POST"});const d=await r.json();if(d.ok){document.getElementById("statusMsg").className="success";document.getElementById("statusMsg").textContent="Berhasil!";document.getElementById("badge").className="badge badge-paired";document.getElementById("badge").textContent="Terdaftar";this.textContent="Sudah terdaftar"}else{document.getElementById("statusMsg").className="error";document.getElementById("statusMsg").textContent=d.error;this.disabled=false;this.innerHTML="Daftarkan laptop ini"}}catch(e){document.getElementById("statusMsg").className="error";document.getElementById("statusMsg").textContent="Gagal konek";this.disabled=false;this.innerHTML="Daftarkan laptop ini"}});document.getElementById("btnUnpair")?.addEventListener("click",async function(){if(!confirm("Lepas pairing?"))return;await fetch("/api/unpair",{method:"POST"});location.reload()});</script></body></html>');
});

app.post('/api/pair', (req, res) => {
  if (STREAM_TYPE === 'rtsp') return res.json({ ok: false, error: 'RTSP mode — set RTSP_URL di .env' });
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  if (!ip || ip === '::1' || ip === '127.0.0.1') return res.json({ ok: false, error: 'Buka dari laptop sumber DroidCam' });
  const c = ip.replace(/^::ffff:/, '');
  sourceUrl = 'http://' + c + ':4747/video';
  fs.writeFileSync(PAIRED_IP_FILE, c);
  console.log('[pair]', sourceUrl);
  if (broadcaster._running) { broadcaster.stop(); broadcaster.start(); }
  res.json({ ok: true, ip: c, url: sourceUrl });
});

app.post('/api/unpair', (req, res) => {
  if (fs.existsSync(PAIRED_IP_FILE)) fs.unlinkSync(PAIRED_IP_FILE);
  sourceUrl = STREAM_TYPE === 'rtsp' ? RTSP_URL : (process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video');
  if (broadcaster._running) { broadcaster.stop(); broadcaster.start(); }
  res.json({ ok: true });
});

app.get('/mjpeg', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'multipart/x-mixed-replace; boundary=' + broadcaster._boundary,
    'Cache-Control': 'no-cache,no-store,must-revalidate',
    'Access-Control-Allow-Origin': '*',
  });
  broadcaster.mjpegRes = res;
  broadcaster.refresh();
  req.on('close', () => { if (broadcaster.mjpegRes === res) { broadcaster.mjpegRes = null; broadcaster.refresh(); } });
});

const wss = new WebSocketServer({ server });
wss.on('connection', (ws) => {
  console.log('[ws] Viewer connected (' + wss.clients.size + ' total)');
  broadcaster.clients.add(ws);
  broadcaster.refresh();
  ws.on('close', () => { broadcaster.clients.delete(ws); broadcaster.refresh(); });
  ws.on('error', () => { broadcaster.clients.delete(ws); broadcaster.refresh(); });
});

server.listen(PORT, HOST, () => {
  const label = STREAM_TYPE === 'rtsp' ? 'RTSP (via FFmpeg)' : 'HTTP (DroidCam)';
  console.log('');
  console.log('╔══════════════════════════════════════════╗');
  console.log('║     DroidCam Web Relay Server            ║');
  console.log('║──────────────────────────────────────────║');
  console.log('║  Stream   : ' + label.padEnd(28) + '║');
  console.log('║  Source   : ' + sourceUrl.padEnd(28) + '║');
  console.log('║  Listen   : http://' + HOST + ':' + PORT + ' '.repeat(17) + '║');
  console.log('║  Pairing  : ' + (STREAM_TYPE === 'rtsp' ? 'N/A (RTSP mode)     ' : '/pair               ') + '║');
  console.log('╚══════════════════════════════════════════╝');
  console.log('');
});
SRVEOF

# ── 7. Setup systemd service ────────────────────────────────
echo "[7/8] Setup systemd service..."
cat > /etc/systemd/system/droidcam-relay.service <<SVC
[Unit]
Description=DroidCam Web Relay
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/droidcam-relay
ExecStart=/usr/bin/node /opt/droidcam-relay/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable droidcam-relay

# ── 8. Setup Nginx ──────────────────────────────────────────
echo "[8/8] Setup Nginx for domain $DOMAIN..."
cat > /etc/nginx/sites-available/droidcam <<NGINX
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$RELAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/droidcam /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── SSL via Certbot ──────────────────────────────────────────
echo ""
echo "───────────────────────────────────────────────"
echo " Mau setup SSL (HTTPS) sekarang? (y/n)"
echo "───────────────────────────────────────────────"
read -r DO_SSL

if [ "$DO_SSL" = "y" ] || [ "$DO_SSL" = "Y" ]; then
  # Pastikan DNS domain sudah pointing ke IP VPS (grey cloud)
  echo ""
  echo "!! PENTING !! Pastikan DNS $DOMAIN sudah grey cloud"
  echo "  (Cloudflare → grey cloud, bukan orange proxy)"
  echo "  Tekan ENTER jika sudah siap..."
  read -r

  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || {
    echo "! SSL gagal. Jalankan manual nanti: certbot --nginx -d $DOMAIN"
  }

  systemctl reload nginx
  echo "  SSL OK! https://$DOMAIN"
fi

# ── Start relay ──────────────────────────────────────────────
systemctl start droidcam-relay

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  ✅  SETUP SELESAI!                          ║"
echo "║───────────────────────────────────────────────║"
echo "║                                              ║"
echo "║  STEP 1 — Buka dari LAPTOP SUMBER:           ║"
echo "║    http://$DOMAIN/pair               ║"
echo "║    (atau http://<IP_VPS>:3000/pair)          ║"
echo "║                                              ║"
echo "║  STEP 2 — Klik tombol daftarkan              ║"
echo "║                                              ║"
echo "║  STEP 3 — Buka viewer dari mana aja:         ║"
echo "║    https://droidcam-relay.vercel.app         ║"
echo "║    (frontend Vercel)                         ║"
echo "║                                              ║"
echo "║  Cek status relay:                           ║"
echo "║    curl http://localhost:3000/status          ║"
echo "║                                              ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
