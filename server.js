require('dotenv').config();
const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

// ── Config ────────────────────────────────────────────────────────────────
const PORT       = process.env.PORT       || 3000;
const HOST       = process.env.HOST       || '0.0.0.0';
const RELAY_MODE = process.env.RELAY_MODE || 'proxy';
let DROIDCAM_URL = process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video';
const PAIRED_IP_FILE = path.join(__dirname, '.paired_ip');

// Restore paired IP if exists
if (fs.existsSync(PAIRED_IP_FILE)) {
  const saved = fs.readFileSync(PAIRED_IP_FILE, 'utf-8').trim();
  if (saved) {
    DROIDCAM_URL = `http://${saved}:4747/video`;
    console.log('  Paired IP restored:', saved);
  }
}

// ── App ───────────────────────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

// CORS
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  next();
});
app.use(express.json());

// ── Status ────────────────────────────────────────────────────────────────
app.get('/status', (req, res) => {
  res.json({
    uptime: process.uptime(),
    mode: RELAY_MODE,
    source: DROIDCAM_URL,
    viewers: wss.clients.size,
    paired: fs.existsSync(PAIRED_IP_FILE)
  });
});

// ── Pairing page ──────────────────────────────────────────────────────────
app.get('/pair', (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  const isPaired = fs.existsSync(PAIRED_IP_FILE);
  res.send(`<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>DroidCam Pairing</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;min-height:100vh}
    .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:2.5rem;max-width:480px;width:90%;text-align:center;box-shadow:0 8px 24px rgba(0,0,0,.4)}
    h1{font-size:1.5rem;margin-bottom:.5rem}
    p{color:#8b949e;margin-bottom:1.5rem;font-size:.95rem}
    .badge{display:inline-block;padding:.3rem 1rem;border-radius:999px;font-size:.85rem;margin-bottom:1.5rem}
    .badge-paired{background:#0f3a1e;border:1px solid #238636;color:#7ee787}
    .badge-unpaired{background:#3a0f0f;border:1px solid #863023;color:#ff7b72}
    .ip-box{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:.75rem;font-family:monospace;font-size:1.2rem;margin:1rem 0}
    .btn{display:inline-flex;align-items:center;gap:.5rem;padding:.75rem 2rem;border-radius:8px;border:none;font-size:1rem;cursor:pointer;transition:opacity .15s}
    .btn-primary{background:#238636;color:#fff}.btn-primary:hover{opacity:.85}.btn-primary:disabled{opacity:.5;cursor:not-allowed}
    .btn-danger{background:#da3633;color:#fff;margin-top:.75rem}.btn-danger:hover{opacity:.85}
    .info{font-size:.8rem;color:#484f58;margin-top:1.5rem;line-height:1.5}
    .error{color:#ff7b72}.success{color:#7ee787}
    .spin{display:inline-block;width:16px;height:16px;border:2px solid #fff;border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}
  </style>
</head>
<body>
  <div class="card">
    <h1>📷 DroidCam Pairing</h1>
    <p>Daftarkan laptop ini sebagai sumber kamera</p>
    <div id="badge" class="badge ${isPaired ? 'badge-paired' : 'badge-unpaired'}">
      ${isPaired ? '✓ Terdaftar' : '✗ Belum terdaftar'}
    </div>
    <p style="font-size:.85rem;color:#8b949e">IP terdeteksi:</p>
    <div class="ip-box" id="myIp">${ip}</div>
    <div id="statusMsg"></div>
    <button id="btnPair" class="btn btn-primary" ${isPaired ? 'disabled' : ''}>
      ${isPaired ? '✓ Sudah terdaftar' : '📌 Daftarkan laptop ini'}
    </button>
    ${isPaired ? '<br><button id="btnUnpair" class="btn btn-danger">🔄 Lepas daftar ulang</button>' : ''}
    <div class="info">
      <strong>Syarat:</strong><br>
      1. Laptop sumber install <strong>DroidCam</strong> (mode WiFi)<br>
      2. Laptop & VPS harus saling terhubung<br>
      3. Port 4747 DroidCam terbuka<br><br>
      <strong>Cara:</strong> Buka halaman ini dari browser laptop sumber, klik tombol di atas.
    </div>
  </div>
  <script>
    document.getElementById('btnPair')?.addEventListener('click', async function(){
      this.disabled=true; this.innerHTML='<span class="spin"></span> Mendaftarkan...';
      try {
        const r=await fetch('/api/pair',{method:'POST'});
        const d=await r.json();
        if(d.ok){
          document.getElementById('statusMsg').className='success';
          document.getElementById('statusMsg').textContent='✓ Berhasil! Kamera siap!';
          document.getElementById('badge').className='badge badge-paired';
          document.getElementById('badge').textContent='✓ Terdaftar';
          this.textContent='✓ Sudah terdaftar';
        } else {
          document.getElementById('statusMsg').className='error';
          document.getElementById('statusMsg').textContent='✗ '+d.error;
          this.disabled=false; this.innerHTML='📌 Daftarkan laptop ini';
        }
      } catch(e){
        document.getElementById('statusMsg').className='error';
        document.getElementById('statusMsg').textContent='✗ Gagal konek ke server';
        this.disabled=false; this.innerHTML='📌 Daftarkan laptop ini';
      }
    });
    document.getElementById('btnUnpair')?.addEventListener('click', async function(){
      if(!confirm('Lepas pairing?')) return;
      await fetch('/api/unpair',{method:'POST'});
      location.reload();
    });
  </script>
</body>
</html>`);
});

// ── API: Pair ──────────────────────────────────────────────────────────────
app.post('/api/pair', (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  if (!ip || ip === '::1' || ip === '127.0.0.1') {
    return res.json({ ok: false, error: 'Buka dari laptop sumber DroidCam, bukan server ini' });
  }
  const cleanIp = ip.replace(/^::ffff:/, '');
  DROIDCAM_URL = `http://${cleanIp}:4747/video`;
  fs.writeFileSync(PAIRED_IP_FILE, cleanIp);
  console.log('[pair] Source set to:', DROIDCAM_URL);
  res.json({ ok: true, ip: cleanIp, url: DROIDCAM_URL });
});

// ── API: Unpair ────────────────────────────────────────────────────────────
app.post('/api/unpair', (req, res) => {
  if (fs.existsSync(PAIRED_IP_FILE)) fs.unlinkSync(PAIRED_IP_FILE);
  DROIDCAM_URL = process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video';
  res.json({ ok: true });
});

// ── Direct MJPEG stream ───────────────────────────────────────────────────
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

// ── WebSocket server ──────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  console.log(`[ws] Viewer connected (${wss.clients.size} total)`);
  if (RELAY_MODE === 'proxy') {
    const { startStream, stopStream } = proxyStreamToClient(ws);
    ws._stopStream = stopStream;
    startStream();
  }
  ws.on('close', () => { if (ws._stopStream) ws._stopStream(); });
  ws.on('error', () => { if (ws._stopStream) ws._stopStream(); });
});

function proxyStreamToClient(ws) {
  let reading = false;
  async function startStream() {
    if (reading) return;
    reading = true;
    try {
      const response = await fetch(DROIDCAM_URL);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
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

function extractBoundary(contentType) {
  const match = contentType.match(/boundary=(\S+)/);
  return match ? match[1] : '--jpgboundary';
}

function extractJpegFrame(buffer, boundary) {
  const b = new TextEncoder().encode('--' + boundary);
  const h = new TextEncoder().encode('\r\nContent-Type: image/jpeg');
  const c = new TextEncoder().encode('\r\n\r\n');
  const bi = findSequence(buffer, b); if (bi === -1) return null;
  const hi = findSequence(buffer, h, bi + b.length); if (hi === -1) return null;
  const di = findSequence(buffer, c, hi + h.length); if (di === -1) return null;
  const sj = di + c.length;
  const ni = findSequence(buffer, b, sj);
  const len = ni !== -1 ? ni - sj - 2 : buffer.length - sj;
  return len > 0 ? { start: sj, length: len } : null;
}

function findSequence(buffer, seq, startOffset = 0) {
  outer: for (let i = startOffset; i <= buffer.length - seq.length; i++) {
    for (let j = 0; j < seq.length; j++) {
      if (buffer[i + j] !== seq[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ── Start ─────────────────────────────────────────────────────────────────
server.listen(PORT, HOST, () => {
  console.log(`
╔══════════════════════════════════════════╗
║     DroidCam Web Relay Server            ║
║──────────────────────────────────────────║
║  Source    : ${DROIDCAM_URL.padEnd(28)}║
║  Listen    : http://${HOST}:${PORT}${' '.repeat(17)}║
║  Pairing   : /pair                       ║
╚══════════════════════════════════════════╝`);
});
