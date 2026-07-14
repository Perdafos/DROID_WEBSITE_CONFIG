(function () {
  'use strict';

  const canvas  = document.getElementById('canvas');
  const ctx     = canvas.getContext('2d', { alpha: false });
  const status  = document.getElementById('status');
  const fpsSpan = document.getElementById('fps');
  const resSpan = document.getElementById('resolution');
  const latSpan = document.getElementById('latency');

  // WebSocket URL from config.js
  const wsUrl = RELAY_SERVER;

  let ws, frameTimer, frameCount = 0, lastFpsTime = 0;

  // ── FPS counter ──────────────────────────────────────
  function updateFps() {
    const now = performance.now();
    if (now - lastFpsTime >= 1000) {
      fpsSpan.textContent = `${frameCount} FPS`;
      frameCount = 0;
      lastFpsTime = now;
    }
  }

  // ── Render JPEG frame from binary blob ───────────────
  function renderFrame(blob) {
    const img = new Image();
    const url = URL.createObjectURL(blob);

    img.onload = function () {
      // Set canvas size only on first frame or size change
      if (canvas.width !== img.naturalWidth || canvas.height !== img.naturalHeight) {
        canvas.width  = img.naturalWidth;
        canvas.height = img.naturalHeight;
        resSpan.textContent = `${img.naturalWidth}×${img.naturalHeight}`;
      }

      ctx.drawImage(img, 0, 0);
      URL.revokeObjectURL(url);

      frameCount++;
      updateFps();
    };

    img.onerror = function () {
      URL.revokeObjectURL(url);
    };

    img.src = url;
  }

  // ── WebSocket connection ─────────────────────────────
  function connect() {
    setStatus('Connecting');
    hidePlaceholder();

    if (ws) {
      ws.onclose = null;
      ws.onerror = null;
      ws.close();
    }

    ws = new WebSocket(wsUrl);
    ws.binaryType = 'blob';

    ws.onopen = function () {
      setStatus('Connected');
      hidePlaceholder();
      console.log('WebSocket connected');
    };

    ws.onmessage = function (event) {
      try {
        // Check if it's a text message (error/JSON)
        if (typeof event.data === 'string') {
          const msg = JSON.parse(event.data);
          if (msg.error) {
            showError(msg.error);
          }
          return;
        }
      } catch (_) { /* not JSON, ignore */ }

      // Binary frame — render it
      renderFrame(event.data);
    };

    ws.onclose = function () {
      setStatus('Disconnected');
      showPlaceholder();
      // Auto-reconnect after 3s
      setTimeout(connect, 3000);
    };

    ws.onerror = function () {
      // onclose fires after onerror, so status is set there
    };
  }

  // ── UI helpers ───────────────────────────────────────
  function setStatus(text) {
    status.textContent = text;
    if (text === 'Connected') {
      status.className = 'status connected';
    } else if (text === 'Connecting') {
      status.className = 'status connecting';
    } else {
      status.className = 'status disconnected';
    }
  }

  function showPlaceholder() {
    const el = document.getElementById('placeholder');
    el.querySelector('p').textContent = 'Menunggu stream...';
    el.querySelector('small').textContent = 'Pastikan laptop sumber terhubung ke server';
    el.style.display = 'flex';
  }

  function hidePlaceholder() {
    document.getElementById('placeholder').style.display = 'none';
  }

  function showError(msg) {
    const el = document.getElementById('placeholder');
    el.style.display = 'flex';
    el.querySelector('p').textContent = '⚠️ ' + msg;
    el.querySelector('small').textContent = 'Coba refresh halaman';
  }

  // ── Controls ─────────────────────────────────────────
  document.getElementById('btnFullscreen').addEventListener('click', function () {
    const v = document.getElementById('viewer');
    if (v.requestFullscreen) {
      v.requestFullscreen();
    } else if (v.webkitRequestFullscreen) {
      v.webkitRequestFullscreen();
    }
  });

  document.getElementById('btnMute').addEventListener('click', function () {
    this.textContent = this.textContent.includes('Mute') ? '🔊 Unmute' : '🔇 Mute';
    // DroidCam video-only, no audio — placeholder for future
  });

  // ── Start ────────────────────────────────────────────
  lastFpsTime = performance.now();
  connect();
})();
