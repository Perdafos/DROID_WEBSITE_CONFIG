require('dotenv').config();
const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');

// ── Config ────────────────────────────────────────────────────────────────
const PORT       = process.env.PORT       || 3000;
const HOST       = process.env.HOST       || '0.0.0.0';
const RELAY_MODE = process.env.RELAY_MODE || 'proxy';
const DROIDCAM_URL = process.env.DROIDCAM_URL || 'http://192.168.1.100:4747/video';

// ── App ───────────────────────────────────────────────────────────────────
const app = express();
const server = http.createServer(app);

// Static files
app.use(express.static('public'));

// Direct MJPEG viewer page (fallback)
app.get('/direct', (req, res) => {
  res.sendFile(__dirname + '/public/direct.html');
});

// Health check
app.get('/status', (req, res) => {
  res.json({ uptime: process.uptime(), mode: RELAY_MODE, viewers: wss.clients.size });
});

// Direct MJPEG stream passthrough (for /direct page)
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

// ── WebSocket server (for proxy mode viewers) ────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  console.log(`[+] Viewer connected (${wss.clients.size} total)`);

  if (RELAY_MODE === 'proxy') {
    // Start forwarding stream to this viewer
    const { startStream, stopStream } = proxyStreamToClient(ws);
    ws._stopStream = stopStream;
    startStream();
  }

  ws.on('close', () => {
    console.log(`[-] Viewer left (${wss.clients.size} remaining)`);
    if (ws._stopStream) ws._stopStream();
  });

  ws.on('error', () => {
    if (ws._stopStream) ws._stopStream();
  });
});

// ── Proxy stream: fetch MJPEG from DroidCam, forward via WebSocket ──────
function proxyStreamToClient(ws) {
  let reading = false;

  async function startStream() {
    if (reading) return;
    reading = true;

    try {
      const response = await fetch(DROIDCAM_URL);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const contentType = response.headers.get('content-type') || '';
      if (!contentType.includes('multipart/x-mixed-replace')) {
        // Might be a direct JPEG stream (DroidCam on some configs)
        console.log('  Content-Type:', contentType);
      }

      const reader = response.body.getReader();
      const boundary = extractBoundary(contentType);

      let buffer = new Uint8Array(0);

      while (reading) {
        const { done, value } = await reader.read();
        if (done) break;

        // Append new chunk
        const combined = new Uint8Array(buffer.length + value.length);
        combined.set(buffer);
        combined.set(value, buffer.length);
        buffer = combined;

        // Extract complete JPEG frames
        while (reading) {
          const frame = extractJpegFrame(buffer, boundary);
          if (!frame) break;

          // Send frame to this viewer only if connection is open
          if (ws.readyState === 1) {
            ws.send(frame, { binary: true });
          }

          // Keep remaining bytes
          buffer = buffer.slice(frame.start + frame.length);
        }
      }
    } catch (err) {
      console.error('Stream error:', err.message);
      if (ws.readyState === 1) {
        ws.send(JSON.stringify({ error: err.message }));
      }
    } finally {
      reading = false;
    }
  }

  function stopStream() {
    reading = false;
  }

  return { startStream, stopStream };
}

// ── MJPEG boundary / frame helpers ──────────────────────────────────────
function extractBoundary(contentType) {
  const match = contentType.match(/boundary=(\S+)/);
  return match ? match[1] : '--jpgboundary';
}

function extractJpegFrame(buffer, boundary) {
  const boundaryStr = '--' + boundary;
  const boundaryBytes = new TextEncoder().encode(boundaryStr);
  const headerBytes  = new TextEncoder().encode('\r\nContent-Type: image/jpeg');
  const doubleCRLF   = new TextEncoder().encode('\r\n\r\n');

  // Find boundary start
  const boundIdx = findSequence(buffer, boundaryBytes);
  if (boundIdx === -1) return null;

  // Find Content-Type header after boundary
  const headerIdx = findSequence(buffer, headerBytes, boundIdx + boundaryBytes.length);
  if (headerIdx === -1) return null;

  // Find double CRLF (end of headers)
  const dataStart = findSequence(buffer, doubleCRLF, headerIdx + headerBytes.length);
  if (dataStart === -1) return null;

  const jpegStart = dataStart + doubleCRLF.length;

  // Find next boundary (end of this frame)
  const nextBoundIdx = findSequence(buffer, boundaryBytes, jpegStart);
  const jpegLength = nextBoundIdx !== -1
    ? nextBoundIdx - jpegStart - 2  // strip trailing \r\n
    : buffer.length - jpegStart;

  if (jpegLength <= 0) return null;

  return { start: jpegStart, length: jpegLength };
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
║  Mode      : ${RELAY_MODE.padEnd(28)}║
║  Source    : ${DROIDCAM_URL.padEnd(28)}║
║  Listen    : http://${HOST}:${PORT}${' '.repeat(17)}║
║  WebSocket : ws://${HOST}:${PORT}${' '.repeat(21)}║
╚══════════════════════════════════════════╝`);
});
