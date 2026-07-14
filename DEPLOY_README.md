# DroidCam Web Relay — Deploy Guide

## Arsitektur

```
┌──────────────────────┐   WebSocket (WSS)   ┌────────────────────┐   MJPEG/HTTP   ┌──────────────┐
│  Vercel (Frontend)   │ ←───────────────── │  VPS Debian         │ ←──────────── │ DroidCam      │
│  droidcam-relay      │  wss://doridcam.    │  (Relay Server)     │   :4747/video  │ Laptop Sumber │
│  .vercel.app         │  perdafos.my.id     │  Port 3000          │                │              │
└──────────────────────┘                     └────────────────────┘                └──────────────┘
```

## Deploy Frontend ke Vercel

```bash
# Buat repo GitHub → push
git remote add origin https://github.com/USERNAME/droidcam-relay.git
git push -u origin main
```

1. Buka https://vercel.com → Import repo
2. Framework: **Other**
3. Output Directory: **public**
4. Deploy! Dapet URL `https://droidcam-relay.vercel.app`

**Sudah siap** — `config.js` di repo sudah pointing ke `wss://doridcam.perdafos.my.id`.

---

## Setup Relay Server di VPS (via Proxmox console)

**PENTING:** Pastikan DNS `doridcam.perdafos.my.id` sudah pointing ke IP publik VPS.
Di Cloudflare: set ke **grey cloud** (☁️ mati) biar bisa HTTPS.

Copy script ke VPS lalu jalanin:

### Cara 1: Download langsung di VPS

```bash
# Di console VPS, jalanin sebagai root:
wget -O setup.sh https://raw.githubusercontent.com/USERNAME/droidcam-relay/main/setup.sh
bash setup.sh
```

### Cara 2: Manual copy-paste ke VPS

```bash
# Di console VPS (sebagai root):
apt install -y git
git clone https://github.com/USERNAME/droidcam-relay.git /tmp/droidcam
cp /tmp/droidcam/setup.sh /root/
bash /root/setup.sh
```

### Cara 3: Satu per satu

Kalo mau manual, run step ini di VPS:

```bash
# 1. Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx git

# 2. Setup project
cd /opt && git clone https://github.com/USERNAME/droidcam-relay.git droidcam-relay
cd droidcam-relay && npm install --production

# 3. Jalankan relay
node server.js

# 4. Setup Nginx + SSL → liat script setup.sh untuk konfigurasi lengkap
```

**Setelah setup selesai**, liat output terminal:

```
╔═══════════════════════════════════════════╗
║  ✅  SETUP SELESAI!                       ║
║───────────────────────────────────────────║
║  STEP 1 — Buka dari LAPTOP SUMBER:        ║
║    http://doridcam.perdafos.my.id/pair    ║
║                                           ║
║  STEP 2 — Klik tombol "Daftarkan laptop"  ║
║                                           ║
║  STEP 3 — Buka viewer:                    ║
║    https://droidcam-relay.vercel.app      ║
╚═══════════════════════════════════════════╝
```

---

## Pairing (One-Click)

**Cukup sekali:** Dari browser laptop sumber DroidCam, buka:

```
https://doridcam.perdafos.my.id/pair
```

Lalu klik **"📌 Daftarkan laptop ini"** — otomatis:
- Deteksi IP laptop
- Simpan ke `.paired_ip` di server
- `DROIDCAM_URL` langsung berubah

Gak perlu edit config manual.

---

## Endpoints Relay Server

| Endpoint | Fungsi |
|----------|--------|
| `/` | 404 (frontend di Vercel) |
| `/status` | Status relay + jumlah viewer |
| `/mjpeg` | Direct MJPEG stream |
| `/pair` | Halaman pairing (one-click) |
| `/api/pair` | API pairing (POST) |
| `/api/unpair` | API un-pair (POST) |

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
