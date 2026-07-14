require('dotenv').config();
const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');

// ── Config ────────────────────────────────────────────────────────────────
const PORT          = process.env.PORT          || 3000;
const HOST          = process.env.HOST          || '0.0.0.0';
const STREAM_TYPE   = process.env.STREAM_TYPE   || 'http';       // 'http' | 'rtsp'
const DROIDCAM_URL  = process.env.DROIDCAM_URL  || 'http://192.168.1.100:4747/video';
const RTSP_URL      = process.env.RTSP_URL      || '';
const PAIRED_IP_FILE = path.join(__dirname, '.paired_ip');

// Runtime source URL (may change via pairing in HTTP mode)
let sourceUrl = STREAM_TYPE === 'rtsp' ? RTSP_URL : DROIDCAM_URL;

// Restore paired IP for HTTP mode
if (STREAM_TYPE !== 'rtsp' && fs.existsSync(PAIRED_IP_FILE)) {
  const saved = fs.readFileSync(PAIRED_IP_FILE, 'utf-8').trim();
  if (saved) {
    sourceUrl = `http://${saved}:4747/video`;
    console.log('  Paired IP restored:', saved);
  }
}

// ── App ───────────────────────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  next();
});
app.use(express.json());

// ══════════════════════════════════════════════════════════════════════════
//  StreamBroadcaster — shared pipeline for HTTP or RTSP source
// ══════════════════════════════════════════════════════════════════════════
class StreamBroadcaster {
  constructor() {
    this.clients = new Set();      // WebSocket connections
    this.mjpegRes = null;          // Current /mjpeg HTTP response
    this._ffmpeg = null;
    this._fetchAbort = null;
    this._buffer = null;           // Accumulated input bytes (HTTP mode)
    this._rtspBuf = null;          // Accumulated input bytes (RTSP mode)
    this._running = false;
    this._restartTimer = null;
    this._boundary = '--jpgboundary';
    this._hasViewers = false;
  }

  get url() { return sourceUrl; }

  // Called when any viewer connects/disconnects
  refresh() {
    const hasViewers = this.clients.size > 0 || this.mjpegRes !== null;
    if (hasViewers && !this._running) {
      this.start();
    } else if (!hasViewers && this._running) {
      this.stop();
    }
  }

  async start() {
    if (this._running) return;
    this._running = true;
    this._buffer = Buffer.alloc(0);
    this._rtspBuf = Buffer.alloc(0);
    console.log(`[broadcaster] Start (${STREAM_TYPE}): ${sourceUrl}`);

    try {
      if (STREAM_TYPE === 'rtsp') {
        this._startRtsp();
      } else {
        await this._startHttp();
      }
    } catch (err) {
      console.error('[broadcaster] Start error:', err.message);
      this._scheduleRestart();
    }
  }

  stop() {
    this._running = false;
    clearTimeout(this._restartTimer);
    this._restartTimer = null;

    if (this._ffmpeg) {
      try { this._ffmpeg.kill('SIGTERM'); } catch (e) { /* ignore */ }
      setTimeout(() => {
        if (this._ffmpeg) {
          try { this._ffmpeg.kill('SIGKILL'); } catch (e) { /* ignore */ }
        }
      }, 2000);
      this._ffmpeg = null;
    }
    if (this._fetchAbort) {
      try { this._fetchAbort.abort(); } catch (e) { /* ignore */ }
      this._fetchAbort = null;
    }
    this._buffer = null;
    this._rtspBuf = null;
    console.log('[broadcaster] Stopped');
  }

  // ── HTTP source (existing DroidCam MJPEG) ────────────────────────────────
  async _startHttp() {
    this._fetchAbort = new AbortController();
    const resp = await fetch(sourceUrl, { signal: this._fetchAbort.signal });
    if (!resp.ok) throw new Error(`DroidCam HTTP ${resp.status}`);

    const ct = resp.headers.get('content-type') || '';
    const m = ct.match(/boundary=(\S+)/);
    this._boundary = m ? m[1] : '--jpgboundary';

    const bDelim = Buffer.from('--' + this._boundary);
    const bHeader = Buffer.from('\r\nContent-Type: image/jpeg');
    const bCrlf   = Buffer.from('\r\n\r\n');
    const reader = resp.body.getReader();

    while (this._running) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!this._running) return;

      this._buffer = Buffer.concat([this._buffer, value]);
      this._processHttpFrames(bDelim, bHeader, bCrlf);
    }

    if (this._running) this._scheduleRestart();
  }

  _processHttpFrames(bDelim, bHeader, bCrlf) {
    const buf = this._buffer;
    let pos = 0;

    while (pos < buf.length) {
      const bi = buf.indexOf(bDelim, pos);
      if (bi === -1) break;
      const hi = buf.indexOf(bHeader, bi + bDelim.length);
      if (hi === -1) break;
      const di = buf.indexOf(bCrlf, hi + bHeader.length);
      if (di === -1) break;

      const frameStart = di + bCrlf.length;
      const ni = buf.indexOf(bDelim, frameStart);
      const frameLen = ni !== -1 ? ni - frameStart - 2 : buf.length - frameStart;

      if (frameLen > 0) {
        this._broadcast(buf.slice(frameStart, frameStart + frameLen));
      }

      if (ni === -1) break;
      pos = ni;
    }

    this._buffer = pos > 0 ? buf.slice(pos) : buf;
  }

  // ── RTSP source (via FFmpeg) ─────────────────────────────────────────────
  _startRtsp() {
    if (!RTSP_URL) {
      console.error('[rtsp] RTSP_URL not set in .env');
      this._broadcastError('RTSP_URL not configured');
      return;
    }

    const ffmpegBin = process.env.FFMPEG_PATH || 'ffmpeg';
    const transport = process.env.RTSP_TRANSPORT || 'tcp';

    this._ffmpeg = spawn(ffmpegBin, [
      '-rtsp_transport', transport,
      '-i', RTSP_URL,
      '-f', 'image2pipe',
      '-vcodec', 'mjpeg',
      '-q:v', process.env.RTSP_QUALITY || '3',
      '-s', process.env.RTSP_SIZE || '640x480',
      '-r', process.env.RTSP_FPS || '15',
      '-an',
      'pipe:1',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });

    let started = false;

    this._ffmpeg.stderr.on('data', (d) => {
      const msg = d.toString();
      if (!started) {
        // First stderr output usually means FFmpeg connected
        started = true;
      }
      // Log errors only
      if (/error|failed|cannot|error/i.test(msg)) {
        console.error('[rtsp]', msg.trim());
      }
    });

    this._ffmpeg.stdout.on('data', (chunk) => {
      if (!this._running) return;
      this._rtspBuf = Buffer.concat([this._rtspBuf, chunk]);
      this._processRtspFrames();
    });

    this._ffmpeg.on('error', (err) => {
      console.error('[rtsp] FFmpeg error:', err.message);
      this._broadcastError(`FFmpeg: ${err.message}`);
      if (this._running) this._scheduleRestart();
    });

    this._ffmpeg.on('exit', (code, signal) => {
      console.log(`[rtsp] FFmpeg exited (code=${code}, signal=${signal})`);
      this._ffmpeg = null;
      if (this._running) this._scheduleRestart();
    });
  }

  _processRtspFrames() {
    const buf = this._rtspBuf;
    if (!buf || buf.length < 2) return;

    let i = 0;
    while (i < buf.length - 1) {
      // SOI = 0xFF 0xD8
      if (buf[i] === 0xFF && buf[i+1] === 0xD8) {
        let j = i + 2;
        while (j < buf.length - 1) {
          // EOI = 0xFF 0xD9
          if (buf[j] === 0xFF && buf[j+1] === 0xD9) {
            const frame = buf.slice(i, j + 2);
            this._broadcast(frame);
            i = j + 2;
            break;
          }
          j++;
        }
        // Incomplete frame — keep remainder
        if (j >= buf.length - 1) break;
      } else {
        // Skip garbage between frames
        i++;
      }
    }

    this._rtspBuf = i > 0 ? buf.slice(i) : buf;
  }

  // ── Broadcasting ─────────────────────────────────────────────────────────
  _broadcast(frame) {
    if (!frame || frame.length === 0) return;

    // WebSocket clients
    for (const ws of this.clients) {
      if (ws.readyState === 1 /** WebSocket.OPEN */) {
        try { ws.send(frame, { binary: true }); } catch (e) { /* ignore */ }
      }
    }

    // MJPEG HTTP response
    if (this.mjpegRes) {
      try {
        this.mjpegRes.write(`--${this._boundary}\r\n`);
        this.mjpegRes.write('Content-Type: image/jpeg\r\n');
        this.mjpegRes.write(`Content-Length: ${frame.length}\r\n\r\n`);
        this.mjpegRes.write(frame);
      } catch (e) {
        this.mjpegRes = null;
        this.refresh();
      }
    }
  }

  _broadcastError(msg) {
    const json = JSON.stringify({ error: msg });
    for (const ws of this.clients) {
      if (ws.readyState === 1) {
        try { ws.send(json); } catch (e) { /* ignore */ }
      }
    }
  }

  // ── Restart ──────────────────────────────────────────────────────────────
  _scheduleRestart() {
    if (!this._running) return;
    clearTimeout(this._restartTimer);
    const delay = 3000;
    console.log(`[broadcaster] Restart in ${delay}ms...`);
    this._restartTimer = setTimeout(() => {
      if (!this._running) return;
      // Check if still needed
      if (this.clients.size === 0 && !this.mjpegRes) {
        this.stop();
        return;
      }
      console.log('[broadcaster] Restarting...');
      this.stop();
      this.start();
    }, delay);
  }
}

const broadcaster = new StreamBroadcaster();

// ══════════════════════════════════════════════════════════════════════════
//  Routes
// ══════════════════════════════════════════════════════════════════════════

// ── Status ──────────────────────────────────────────────────────────────
app.get('/status', (req, res) => {
  res.json({
    uptime: process.uptime(),
    streamType: STREAM_TYPE,
    source: sourceUrl,
    viewers: broadcaster.clients.size,
    paired: STREAM_TYPE !== 'rtsp' && fs.existsSync(PAIRED_IP_FILE),
    rtspConfigured: STREAM_TYPE === 'rtsp' && !!RTSP_URL,
  });
});

// ── Pairing page (HTTP mode only) ───────────────────────────────────────
app.get('/pair', (req, res) => {
  if (STREAM_TYPE === 'rtsp') {
    return res.send(`<!DOCTYPE html>
<html lang="id">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>DroidCam — RTSP Mode</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;min-height:100vh}
  .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:2.5rem;max-width:520px;width:90%;text-align:center;box-shadow:0 8px 24px rgba(0,0,0,.4)}
  h1{font-size:1.5rem;margin-bottom:.5rem}
  p{color:#8b949e;margin-bottom:1.5rem;font-size:.95rem}
  .badge{display:inline-block;padding:.3rem 1rem;border-radius:999px;font-size:.85rem;margin-bottom:1.5rem;background:#1f2e17;border:1px solid #3b6e1f;color:#b1e58b}
  .info{text-align:left;background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:1rem;font-size:.85rem;line-height:1.7;color:#8b949e;margin-top:1rem}
  code{color:#c9d1d9;background:#21262d;padding:.15rem .5rem;border-radius:4px;font-size:.8rem}
</style>
</head>
<body>
  <div class="card">
    <h1>📷 DroidCam — RTSP Mode</h1>
    <div class="badge">◆ RTSP Active</div>
    <p>Stream menggunakan RTSP, pairing tidak tersedia.</p>
    <div class="info">
      <strong>Konfigurasi saat ini:</strong><br>
      URL: <code>${RTSP_URL || '(not set)'}</code><br><br>
      <strong>Ubah di file .env:</strong><br>
      <code>STREAM_TYPE=rtsp</code><br>
      <code>RTSP_URL=rtsp://user:pass@ip:554/stream</code><br><br>
      Restart server setelah ubah .env.
    </div>
  </div>
</body>
</html>`);
  }

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

// ── API: Pair (HTTP mode only) ──────────────────────────────────────────
app.post('/api/pair', (req, res) => {
  if (STREAM_TYPE === 'rtsp') {
    return res.json({ ok: false, error: 'RTSP mode — set RTSP_URL di .env' });
  }
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress;
  if (!ip || ip === '::1' || ip === '127.0.0.1') {
    return res.json({ ok: false, error: 'Buka dari laptop sumber DroidCam, bukan server ini' });
  }
  const cleanIp = ip.replace(/^::ffff:/, '');
  sourceUrl = `http://${cleanIp}:4747/video`;
  fs.writeFileSync(PAIRED_IP_FILE, cleanIp);
  console.log('[pair] Source set to:', sourceUrl);
  // Restart broadcaster if active
  if (broadcaster._running) {
    broadcaster.stop();
    broadcaster.start();
  }
  res.json({ ok: true, ip: cleanIp, url: sourceUrl });
});

// ── API: Unpair ─────────────────────────────────────────────────────────
app.post('/api/unpair', (req, res) => {
  if (fs.existsSync(PAIRED_IP_FILE)) fs.unlinkSync(PAIRED_IP_FILE);
  sourceUrl = STREAM_TYPE === 'rtsp' ? RTSP_URL : (process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video');
  // Restart broadcaster if active
  if (broadcaster._running) {
    broadcaster.stop();
    broadcaster.start();
  }
  res.json({ ok: true });
});

// ── Direct MJPEG stream ────────────────────────────────────────────────
app.get('/mjpeg', async (req, res) => {
  res.writeHead(200, {
    'Content-Type': `multipart/x-mixed-replace; boundary=${broadcaster._boundary}`,
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    'Pragma': 'no-cache',
    'Expires': '0',
    'Access-Control-Allow-Origin': '*',
    'Connection': 'close',
  });

  broadcaster.mjpegRes = res;
  broadcaster.refresh();

  req.on('close', () => {
    if (broadcaster.mjpegRes === res) {
      broadcaster.mjpegRes = null;
      broadcaster.refresh();
    }
  });
});

// ── WebSocket server ────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws) => {
  console.log(`[ws] Viewer connected (${wss.clients.size} total)`);
  broadcaster.clients.add(ws);
  broadcaster.refresh();

  ws.on('close', () => {
    broadcaster.clients.delete(ws);
    console.log(`[ws] Viewer disconnected (${broadcaster.clients.size} remaining)`);
    broadcaster.refresh();
  });

  ws.on('error', () => {
    broadcaster.clients.delete(ws);
    broadcaster.refresh();
  });
});

// ══════════════════════════════════════════════════════════════════════════
//  Start
// ══════════════════════════════════════════════════════════════════════════
server.listen(PORT, HOST, () => {
  const urlDisplay = sourceUrl.padEnd(28);
  console.log(`
╔══════════════════════════════════════════╗
║     DroidCam Web Relay Server            ║
║──────────────────────────────────────────║
║  Stream   : ${STREAM_TYPE === 'rtsp' ? 'RTSP (via FFmpeg)'.padEnd(28) : 'HTTP (DroidCam)'.padEnd(28)}║
║  Source   : ${urlDisplay}║
║  Listen   : http://${HOST}:${PORT}${' '.repeat(17)}║
║  Pairing  : ${STREAM_TYPE === 'rtsp' ? 'N/A (RTSP mode)    ' : '/pair               '}║
╚══════════════════════════════════════════╝`);
});
