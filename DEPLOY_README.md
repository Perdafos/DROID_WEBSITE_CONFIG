# DroidCam Web Relay — Deploy Guide

## Arsitektur

```
┌──────────────────────┐   WebSocket (WSS)   ┌────────────────────┐   MJPEG/HTTP    ┌──────────────┐
│  Vercel (Frontend)   │ ←───────────────── │  VPS Debian         │ ←───────────── │ DroidCam      │
│  droidcam-relay      │  wss://doridcam.    │  (Relay Server)     │   :4747/video  │ Laptop Sumber │
│  .vercel.app         │  perdafos.my.id     │  Port 3000          │                │              │
└──────────────────────┘                     └────────────────────┘                └──────────────┘
                                                                                         │
                                                    Atau (mode RTSP):                    │
                                                    ┌────────────────────┐   RTSP        │
                                                    │  Camera IP / NVR   │ ←────────────┘
                                                    │  (via FFmpeg)      │
                                                    └────────────────────┘
```

Project ini bisa pake **2 mode stream**:
- **HTTP** — DroidCam WiFi HTTP MJPEG (default, bisa pake pairing)
- **RTSP** — Camera IP/NVR via FFmpeg transcoding (tidak bisa pairing, config manual)

---

## Mode HTTP (DroidCam — default)

### Deploy Frontend ke Vercel

```bash
git remote add origin https://github.com/USERNAME/droidcam-relay.git
git push -u origin main
```

1. Buka https://vercel.com → Import repo
2. Framework: **Other**
3. Output Directory: **public**
4. Deploy! Dapat URL `https://droidcam-relay.vercel.app`

### Setup Relay Server di VPS

Copy script ke VPS lalu jalankan:

```bash
wget -O setup.sh https://raw.githubusercontent.com/USERNAME/droidcam-relay/main/setup.sh
bash setup.sh
```

### Pairing (One-Click)

Dari browser laptop sumber DroidCam, buka:

```
https://doridcam.perdafos.my.id/pair
```

Klik **"📌 Daftarkan laptop ini"** — otomatis:
- Deteksi IP laptop
- Simpan ke `.paired_ip` di server
- `DROIDCAM_URL` langsung berubah

---

## Mode RTSP (Camera IP / NVR)

### 1. Setup VPS

```bash
# Clone dan install
git clone https://github.com/USERNAME/droidcam-relay.git /opt/droidcam-relay
cd /opt/droidcam-relay
npm install --production

# Install FFmpeg (wajib untuk RTSP)
apt install -y ffmpeg
```

### 2. Konfigurasi .env

Edit `/opt/droidcam-relay/.env`:

```
STREAM_TYPE=rtsp
RTSP_URL=rtsp://username:password@192.168.1.100:554/stream1

RTSP_TRANSPORT=tcp
RTSP_FPS=15
RTSP_SIZE=640x480
RTSP_QUALITY=3
FFMPEG_PATH=ffmpeg

PORT=3000
HOST=0.0.0.0
```

### 3. Jalankan

```bash
node server.js
```

Atau setup systemd + Nginx + SSL (lihat bagian setup.sh).

### 4. Buka Viewer

Frontend Vercel → otomatis connect ke `wss://doridcam.perdafos.my.id`

Atau langsung:

| Mode | URL |
|------|-----|
| RTSP via FFmpeg | `http://<VPS_IP>:3000/mjpeg` |
| WebSocket | `ws://<VPS_IP>:3000` |

---

## Endpoints Relay Server

| Endpoint | Fungsi |
|----------|--------|
| `/` | 404 (frontend di Vercel) |
| `/status` | Status relay + stream type + jumlah viewer |
| `/mjpeg` | Direct MJPEG stream |
| `/pair` | Halaman pairing (HTTP mode) / info config (RTSP mode) |
| `/api/pair` | API pairing (POST) — HTTP only |
| `/api/unpair` | API un-pair (POST) — HTTP only |

### /status Response

```json
{
  "uptime": 12345,
  "streamType": "rtsp",
  "source": "rtsp://user:pass@192.168.1.100:554/stream1",
  "viewers": 2,
  "paired": false
}
```

---

## RTSP Fine-Tuning

| Env Var | Default | Keterangan |
|---------|---------|------------|
| `RTSP_TRANSPORT` | `tcp` | Protocol: `tcp` lebih stabil, `udp` lebih murah bandwidth |
| `RTSP_FPS` | `15` | Output framerate — makin rendah makin hemat bandwidth |
| `RTSP_SIZE` | `640x480` | Output resolusi. VGA cukup utk monitoring |
| `RTSP_QUALITY` | `3` | JPEG quality 1-31, lower = lebih bagus. 1-5 utk web |
| `FFMPEG_PATH` | `ffmpeg` | Path ke ffmpeg binary |

**Tips performa:**
- RTSP camera lokal (LAN) → set FPS 20-30
- RTSP lewat internet → set FPS 10-15, SIZE 320x240 atau 640x480
- Kalau sering disconnect → ganti `RTSP_TRANSPORT=udp`

---

## Maintenance

```bash
# Cek status
systemctl status droidcam-relay
journalctl -u droidcam-relay -f

# Restart
systemctl restart droidcam-relay

# Update kode
cd /opt/droidcam-relay
git pull
systemctl restart droidcam-relay
```
