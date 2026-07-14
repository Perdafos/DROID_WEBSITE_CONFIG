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
# DroidCam source — diisi otomatis via pairing page
DROIDCAM_URL=http://192.168.1.100:4747/video

# Server config
PORT=$RELAY_PORT
HOST=0.0.0.0
RELAY_MODE=proxy

# Simpan IP hasil pairing (biar persist重启)
# Jangan diedit manual — diatur via /api/pair
PAIRED_IP=
ENVFILE

# ── 6. Create server.js ─────────────────────────────────────
echo "[6/8] Create server.js..."
cat > server.js <<'SRVEOF'
require('dotenv').config();
const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

// ── Config ──────────────────────────────────────────────────
const PORT       = process.env.PORT       || 3000;
const HOST       = process.env.HOST       || '0.0.0.0';
const RELAY_MODE = process.env.RELAY_MODE || 'proxy';
let DROIDCAM_URL = process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video';
const ENV_PATH   = path.join(__dirname, '.env');
const PAIRED_IP_FILE = path.join(__dirname, '.paired_ip');

// Load paired IP kalau ada
if (fs.existsSync(PAIRED_IP_FILE)) {
  const saved = fs.readFileSync(PAIRED_IP_FILE, 'utf-8').trim();
  if (saved) {
    DROIDCAM_URL = `http://${saved}:4747/video`;
    console.log('  Paired IP restored:', saved);
  }
}

// ── App ─────────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

// CORS
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  next();
});

// Parse JSON body buat pairing
app.use(express.json());

// ── Status ──────────────────────────────────────────────────
app.get('/status', (req, res) => {
  res.json({
    uptime: process.uptime(),
    mode: RELAY_MODE,
    source: DROIDCAM_URL,
    viewers: wss.clients.size,
    paired: DROIDCAM_URL !== 'http://192.168.1.100:4747/video'
  });
});

// ── Pairing page ────────────────────────────────────────────
app.get('/pair', (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  const isPaired = fs.existsSync(PAIRED_IP_FILE);
  res.send(`<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>DroidCam — Pairing</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d1117; color: #c9d1d9;
      display: flex; justify-content: center; align-items: center; min-height: 100vh;
    }
    .card {
      background: #161b22; border: 1px solid #30363d; border-radius: 12px;
      padding: 2.5rem; max-width: 480px; width: 100%; text-align: center;
      box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    }
    h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
    p { color: #8b949e; margin-bottom: 1.5rem; font-size: 0.95rem; }
    .status-badge {
      display: inline-block; padding: 0.3rem 1rem; border-radius: 999px;
      font-size: 0.85rem; margin-bottom: 1.5rem;
    }
    .badge-paired { background: #0f3a1e; border: 1px solid #238636; color: #7ee787; }
    .badge-unpaired { background: #3a0f0f; border: 1px solid #863023; color: #ff7b72; }
    .badge-pairing { background: #1f2e17; border: 1px solid #3b6e1f; color: #b1e58b; }
    .btn {
      display: inline-flex; align-items: center; gap: 0.5rem;
      padding: 0.75rem 2rem; border-radius: 8px; border: none;
      font-size: 1rem; cursor: pointer; transition: opacity 0.15s;
    }
    .btn-primary { background: #238636; color: #fff; }
    .btn-primary:hover { opacity: 0.85; }
    .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-danger { background: #da3633; color: #fff; }
    .btn-danger:hover { opacity: 0.85; }
    .ip-display {
      background: #0d1117; border: 1px solid #30363d; border-radius: 6px;
      padding: 0.75rem; font-family: monospace; font-size: 1.2rem; margin: 1rem 0;
    }
    .info { font-size: 0.8rem; color: #484f58; margin-top: 1.5rem; line-height: 1.5; }
    .error { color: #ff7b72; font-size: 0.85rem; margin-top: 0.5rem; }
    .success { color: #7ee787; font-size: 0.85rem; margin-top: 0.5rem; }
    .hidden { display: none; }
    .loader {
      display: inline-block; width: 16px; height: 16px; border: 2px solid #fff;
      border-top-color: transparent; border-radius: 50%; animation: spin 0.6s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="card">
    <h1>📷 DroidCam Pairing</h1>
    <p>Daftarkan laptop ini sebagai sumber kamera</p>
    <div id="badge" class="status-badge ${isPaired ? 'badge-paired' : 'badge-unpaired'}">
      ${isPaired ? '✓ Terdaftar' : '✗ Belum terdaftar'}
    </div>

    <p style="font-size:0.85rem;color:#8b949e;">IP terdeteksi:</p>
    <div class="ip-display" id="myIp">${ip}</div>

    <div id="statusMsg"></div>

    <button id="btnPair" class="btn btn-primary" ${isPaired ? 'disabled' : ''}>
      ${isPaired ? '✓ Sudah terdaftar' : '📌 Daftarkan laptop ini'}
    </button>

    ${isPaired ? `<button id="btnUnpair" class="btn btn-danger" style="margin-top:0.75rem;">🔄 Lepas & daftar ulang</button>` : ''}

    <div class="info">
      <strong>Syarat:</strong><br />
      1. Laptop sumber harus install <strong>DroidCam</strong> (mode WiFi)<br />
      2. Laptop dan VPS ini harus bisa saling terhubung<br />
      3. Port <strong>4747</strong> DroidCam harus terbuka<br /><br />
      <strong>Cara:</strong> Buka halaman ini dari browser laptop sumber,<br />
      lalu klik tombol di atas.
    </div>
  </div>

  <script>
    const btnPair = document.getElementById('btnPair');
    const btnUnpair = document.getElementById('btnUnpair');
    const badge = document.getElementById('badge');
    const statusMsg = document.getElementById('statusMsg');

    btnPair?.addEventListener('click', async function () {
      this.disabled = true;
      this.innerHTML = '<span class="loader"></span> Mendaftarkan...';
      statusMsg.className = '';

      try {
        const res = await fetch('/api/pair', { method: 'POST' });
        const data = await res.json();
        if (data.ok) {
          statusMsg.className = 'success';
          statusMsg.textContent = '✓ Berhasil! Laptop terdaftar sebagai sumber kamera.';
          badge.className = 'status-badge badge-paired';
          badge.textContent = '✓ Terdaftar';
          this.textContent = '✓ Sudah terdaftar';
        } else {
          statusMsg.className = 'error';
          statusMsg.textContent = '✗ Gagal: ' + (data.error || 'unknown');
          this.disabled = false;
          this.innerHTML = '📌 Daftarkan laptop ini';
        }
      } catch (e) {
        statusMsg.className = 'error';
        statusMsg.textContent = '✗ Gagal connect ke server';
        this.disabled = false;
        this.innerHTML = '📌 Daftarkan laptop ini';
      }
    });

    btnUnpair?.addEventListener('click', async function () {
      if (!confirm('Lepas pairing? Laptop lain bisa daftar ulang.')) return;
      try {
        await fetch('/api/unpair', { method: 'POST' });
        location.reload();
      } catch (e) {
        statusMsg.className = 'error';
        statusMsg.textContent = '✗ Gagal';
      }
    });
  </script>
</body>
</html>`);
});

// ── API: Pair — daftarkan IP laptop sumber ──────────────────
app.post('/api/pair', (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;

  if (!ip || ip === '::1' || ip === '127.0.0.1') {
    return res.json({ ok: false, error: 'Gak bisa pairing dari localhost. Buka halaman ini dari laptop sumber DroidCam.' });
  }

  // Filter IP (IPv4 / IPv6)
  const cleanIp = ip.replace(/^::ffff:/, '');
  DROIDCAM_URL = `http://${cleanIp}:4747/video`;
  fs.writeFileSync(PAIRED_IP_FILE, cleanIp);

  console.log('[pair] DroidCam source set to:', DROIDCAM_URL);
  res.json({ ok: true, ip: cleanIp, url: DROIDCAM_URL });
});

// ── API: Unpair ─────────────────────────────────────────────
app.post('/api/unpair', (req, res) => {
  if (fs.existsSync(PAIRED_IP_FILE)) fs.unlinkSync(PAIRED_IP_FILE);
  DROIDCAM_URL = process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video';
  console.log('[unpair] Reset DroidCam source');
  res.json({ ok: true });
});

// ── MJPEG stream ────────────────────────────────────────────
app.get('/mjpeg', async (req, res) => {
  try {
    const response = await fetch(DROIDCAM_URL);
    if (!response.ok) throw new Error(`DroidCam HTTP ${response.status}`);

    res.writeHead(200, {
      'Content-Type': response.headers.get('content-type') || 'multipart/x-mixed-replace; boundary=--jpgboundary',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
      'Access-Control-Allow-Origin': '*',
    });

    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(value);
    }
  } catch (err) {
    res.status(502).send(`Stream error: ${err.message}`);
  }
});

// ── WebSocket server ────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  console.log('[ws] Viewer connected (' + wss.clients.size + ' total)');

  if (RELAY_MODE === 'proxy') {
    const { startStream, stopStream } = proxyStreamToClient(ws);
    ws._stopStream = stopStream;
    startStream();
  }

  ws.on('close', () => {
    console.log('[ws] Viewer disconnected (' + (wss.clients.size - 1) + ' remaining)');
    if (ws._stopStream) ws._stopStream();
  });

  ws.on('error', () => { if (ws._stopStream) ws._stopStream(); });
});

function proxyStreamToClient(ws) {
  let reading = false;

  async function startStream() {
    if (reading) return;
    reading = true;
    try {
      const response = await fetch(DROIDCAM_URL);
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const contentType = response.headers.get('content-type') || '';
      const reader = response.body.getReader();
      const boundary = extractBoundary(contentType);
      let buffer = new Uint8Array(0);

      while (reading) {
        const { done, value } = await reader.read();
        if (done) break;
        const combined = new Uint8Array(buffer.length + value.length);
        combined.set(buffer);
        combined.set(value, buffer.length);
        buffer = combined;
        while (reading) {
          const frame = extractJpegFrame(buffer, boundary);
          if (!frame) break;
          if (ws.readyState === 1) ws.send(buffer.slice(frame.start, frame.start + frame.length), { binary: true });
          buffer = buffer.slice(frame.start + frame.length);
        }
      }
    } catch (err) {
      console.error('[stream] Error:', err.message);
      if (ws.readyState === 1) ws.send(JSON.stringify({ error: err.message }));
    } finally { reading = false; }
  }

  function stopStream() { reading = false; }
  return { startStream, stopStream };
}

function extractBoundary(ct) {
  const m = ct.match(/boundary=(\S+)/);
  return m ? m[1] : '--jpgboundary';
}

function extractJpegFrame(buf, boundary) {
  const b = new TextEncoder().encode('--' + boundary);
  const h = new TextEncoder().encode('\r\nContent-Type: image/jpeg');
  const cr = new TextEncoder().encode('\r\n\r\n');
  const bi = findSeq(buf, b, 0);
  if (bi === -1) return null;
  const hi = findSeq(buf, h, bi + b.length);
  if (hi === -1) return null;
  const di = findSeq(buf, cr, hi + h.length);
  if (di === -1) return null;
  const sj = di + cr.length;
  const ni = findSeq(buf, b, sj);
  const len = ni !== -1 ? ni - sj - 2 : buf.length - sj;
  return len > 0 ? { start: sj, length: len } : null;
}

function findSeq(buf, seq, off) {
  outer: for (let i = off; i <= buf.length - seq.length; i++) {
    for (let j = 0; j < seq.length; j++) {
      if (buf[i + j] !== seq[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ── Start ───────────────────────────────────────────────────
server.listen(PORT, HOST, () => {
  console.log('');
  console.log('╔══════════════════════════════════════════╗');
  console.log('║     DroidCam Web Relay Server            ║');
  console.log('║──────────────────────────────────────────║');
  console.log('║  Relay     : RELAY                       ║');
  console.log('║  Source    : ' + DROIDCAM_URL.padEnd(28) + '║');
  console.log('║  Listen    : http://' + HOST + ':' + PORT + ' '.repeat(13) + '║');
  console.log('║──────────────────────────────────────────║');
  console.log('║  Pairing   : http://<IP>:' + PORT + '/pair  ║');
  console.log('║  Status    : /status                     ║');
  console.log('║  Direct    : /mjpeg                      ║');
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
