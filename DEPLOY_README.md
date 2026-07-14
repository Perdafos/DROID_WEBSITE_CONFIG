# Panduan Deploy DroidCam Web Relay

## Arsitektur

```
┌──────────────────────┐       WebSocket       ┌──────────────────┐     MJPEG/HTTP    ┌──────────────┐
│  Vercel (Frontend)   │ ←──────────────────→ │  VPS / Server     │ ←────────────── │ DroidCam      │
│  - index.html        │   wss://relay-srv:3000 │  (Relay Server)   │   :4747/video   │ Laptop Sumber │
│  - app.js            │                        │  - Node.js        │                 │              │
│  - config.js         │                        │  - WebSocket relay│                 │              │
│  - direct.html       │                        │  - /mjpeg proxy   │                 │              │
└──────────────────────┘                        └──────────────────┘                 └──────────────┘
                       └── https://vercel-domain.vercel.app ──┘
```

## Syarat

| Komponen | Keterangan |
|----------|------------|
| **Vercel** | Hosting frontend (gratis) |
| **VPS / Server Debian** | Relay server — harus reachable dari Vercel & viewer (public IP atau domain) |
| **Laptop Sumber** | Install DroidCam, mode WiFi |
| **Domain** | (Opsional) Untuk relay server, biar pakai WSS (WebSocket Secure) |

---

## Bagian 1: Deploy Frontend ke Vercel

### 1a. Setup GitHub repo

```bash
# Inisialisasi git
cd /d/Droidcam_website_config
git init
git add .
git commit -m "Initial commit: DroidCam web relay frontend + relay server"

# Buat repo di GitHub (lewat browser https://github.com/new)
# Lalu push:
git remote add origin https://github.com/USERNAME/droidcam-relay.git
git push -u origin main
```

### 1b. Deploy ke Vercel

1. Buka https://vercel.com → Import GitHub repo `droidcam-relay`
2. **Framework**: `Other`
3. **Root Directory**: `./` (default)
4. **Build & Output**: biarkan default (Vercel deteksi `public/` via `vercel.json`)
5. Deploy → dapat URL `https://droidcam-relay.vercel.app`

### 1c. Konfigurasi config.js

Vercel akan deploy file `config.js`. Untuk **production**, arahkan ke relay server:

```js
// public/config.js
const RELAY_SERVER = 'wss://relay-server-domain.com';
```

Bisa diganti langsung di GitHub atau via Vercel dashboard setelah deploy.

> **Catatan:** Vercel **tidak support** WebSocket server/streaming backend. Maka dari itu perlu relay server terpisah.

---

## Bagian 2: Relay Server di VPS Debian

### 2a. Install Node.js

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs git
node -v  # harus v20.x
```

### 2b. Setup relay

```bash
# Clone repo
git clone https://github.com/USERNAME/droidcam-relay.git /opt/droidcam-relay
cd /opt/droidcam-relay

# Install dependencies (hanya express + ws)
npm install --production

# Config
cp .env.example .env
nano .env
```

**Isi .env:**
```env
DROIDCAM_URL=http://192.168.1.100:4747/video
PORT=3000
HOST=0.0.0.0
RELAY_MODE=proxy
```

### 2c. Systemd service

```bash
sudo nano /etc/systemd/system/droidcam-relay.service
```

```ini
[Unit]
Description=DroidCam Web Relay Server
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/droidcam-relay
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now droidcam-relay
sudo systemctl status droidcam-relay
```

### 2d. Nginx reverse proxy (domain + SSL)

```bash
sudo apt install -y nginx certbot python3-certbot-nginx

sudo nano /etc/nginx/sites-available/droidcam-relay
```

```nginx
server {
    listen 80;
    server_name relay-server-domain.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/droidcam-relay /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d relay-server-domain.com
```

---

## Bagian 3: Akses & Monitoring

### Viewer

- **Halaman utama**: `https://droidcam-relay.vercel.app` — WebSocket relay (kanvas, FPS, dll.)
- **Direct stream**: `https://droidcam-relay.vercel.app/direct` — MJPEG langsung (fallback)

### Cek status relay

```bash
curl https://relay-server-domain.com/status
# → {"uptime":1234,"mode":"proxy","viewers":3}
```

---

## PENTING: Koneksi Jaringan

Laptop sumber (DroidCam) **harus bisa dijangkau** relay server:

| Skenario | Solusi |
|----------|--------|
| Satu jaringan lokal | Langsung pakai IP lokal (192.168.x.x) |
| Laptop di rumah, VPS di cloud | Port forwarding di router → buka port 4747 |
| Laptop NAT/tidak punya IP publik | Pasang tunnel: **ngrok**, **Cloudflare Tunnel**, atau **ZeroTier** |

### Pakai ZeroTier (rekomendasi paling mudah):

1. Install ZeroTier di laptop sumber & VPS:
   ```bash
   curl -s https://install.zerotier.com | sudo bash
   ```
2. Join network:
   ```bash
   sudo zerotier-cli join <NETWORK_ID>
   ```
3. Set `DROIDCAM_URL` ke IP ZeroTier laptop sumber

---

## Local Development (Testing)

```bash
# 1. Clone & install
cd /opt/droidcam-relay
npm install

# 2. Konfigurasi .env
cp .env.example .env
# → DROIDCAM_URL=http://localhost:4747/video (misal DroidCam di laptop yang sama)

# 3. Jalankan relay server
node server.js

# 4. Di browser: buka public/index.html langsung atau:
#    http://localhost:3000 (karena server juga serve static)
```
