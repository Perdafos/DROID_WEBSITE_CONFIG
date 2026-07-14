# Panduan Deploy DroidCam Web Relay di Debian Server

## 1. Siapkan Sumber Stream (Laptop dengan DroidCam)

1. Install **DroidCam** di laptop
2. Buka DroidCam → mode **WiFi / LAN**
3. Catat **IP laptop** (contoh: `192.168.1.100`)
4. Pastikan port **4747** terbuka (default DroidCam)
5. Test dari server: `curl -I http://192.168.1.100:4747/video`

> **PENTING:** Server Debian HARUS bisa reach ke laptop sumber.
> - Jika beda jaringan: buka port forwarding di router, atau gunakan VPN (WireGuard/ZeroTier).
> - Jika laptop sumber ada di NAT: pasang **ngrok/tunnel** ke port 4747.

---

## 2. Deploy di Server Debian

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs git

# Clone project (atau upload manual)
git clone https://github.com/username/droidcam-relay.git /opt/droidcam-relay
# atau upload via scp:
# scp -r ./* user@server:/opt/droidcam-relay

cd /opt/droidcam-relay

# Buat .env dari contoh
cp .env.example .env
nano .env
# → edit DROIDCAM_URL sesuai IP laptop sumber
# → edit PORT (default 3000)
# → set RELAY_MODE=proxy

# Install dependencies
npm install --production

# Test jalan
node server.js
# → Beres: Ctrl+C, lanjut setup systemd biar auto-start
```

---

## 3. Systemd Service (Auto-start)

```bash
sudo nano /etc/systemd/system/droidcam-relay.service
```

```ini
[Unit]
Description=DroidCam Web Relay
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/droidcam-relay
ExecStart=/usr/bin/node /opt/droidcam-relay/server.js
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

---

## 4. Reverse Proxy dengan Nginx + Domain

```bash
sudo apt install -y nginx certbot python3-certbot-nginx

sudo nano /etc/nginx/sites-available/droidcam.example.com
```

```nginx
server {
    listen 80;
    server_name droidcam.example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeout panjang untuk streaming
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

```bash
# Aktifkan site
sudo ln -s /etc/nginx/sites-available/droidcam.example.com /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# SSL gratis
sudo certbot --nginx -d droidcam.example.com
```

---

## 5. Opsional: Basic Auth

### Di Nginx (rekomendasi):

```nginx
server {
    ...
    auth_basic "DroidCam Monitor";
    auth_basic_user_file /etc/nginx/.htpasswd;
    ...
}
```

```bash
sudo apt install -y apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd admin
```

### Atau di .env (built-in):

Tambahkan kode ke server.js (lihat bagian auth). Uncomment USERNAME/PASSWORD di `.env`.

---

## 6. Maintenance

### Cek log:
```bash
sudo journalctl -u droidcam-relay -f
# atau
tail -f /opt/droidcam-relay/stream.log
```

### Restart:
```bash
sudo systemctl restart droidcam-relay
```

### Update:
```bash
cd /opt/droidcam-relay
git pull
npm install --production
sudo systemctl restart droidcam-relay
```

### Monitoring:
```bash
curl https://droidcam.example.com/status
# → {"uptime":1234,"mode":"proxy","viewers":3}
```

---

## Arsitektur

```
┌──────────────┐    MJPEG/HTTP     ┌──────────────┐    WebSocket     ┌──────────────┐
│  Laptop Src  │ ────────────────→ │ Server Relay  │ ──────────────→ │ Laptop View  │
│  DroidCam    │   port 4747       │  Node.js      │   port 3000     │  Browser     │
│  192.168...  │                   │  debian       │                 │  (banyak)    │
└──────────────┘                   └──────────────┘                 └──────────────┘
                                           │
                                           │ HTTP/MJPEG
                                           ├────────────────────────→ │ /direct page
                                           │                          └──────────────┘
                                           │   (fallback jika WebSocket bermasalah)
```

### Mode:

| Mode | Cara | Latency | Cocok untuk |
|------|------|---------|-------------|
| `proxy` (default) | Server fetch frame → kirim ke viewer via WS | Rendah | Banyak viewer (>5) |
| `direct` | Server kasih tau source IP ke browser | Langsung | Satu jaringan lokal |

### Port yang digunakan:
- **3000** (atau PORT di .env) — web server
- **80/443** — Nginx reverse proxy + SSL
