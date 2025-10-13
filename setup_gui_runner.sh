#!/bin/bash
set -eo pipefail

# Skrip All-in-One untuk Instalasi dan Konfigurasi XFCE, VNC, noVNC, dan Tailscale.

# Pastikan semua variabel lingkungan yang diperlukan ada
if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$TAILSCALE_AUTHKEY" || -z "$TAILSCALE_HOSTNAME" || -z "$VNC_PORT" || -z "$WEBSOCKET_PORT" ]]; then
    echo "ERROR: Beberapa variabel lingkungan yang diperlukan (USERNAME, PASSWORD, TAILSCALE_AUTHKEY, TAILSCALE_HOSTNAME, VNC_PORT, WEBSOCKET_PORT) tidak diset."
    exit 1
fi

echo "=================================================="
echo ">>> BAGIAN 1: INSTALASI DEPENDENSI"
echo "=================================================="

echo ">>> Menginstal Tailscale Repository..."
# Menginstal Tailscale Repository
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo ">>> Menginstal XFCE, VNC, noVNC tools, dan Tailscale client..."
sudo apt-get update -qq

# Paket Instalasi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  xfce4 xfce4-goodies xorg dbus-x11 git python3-websockify socat \
  tigervnc-standalone-server tigervnc-common tigervnc-tools tailscale

# Kloning noVNC
if [ ! -d "/opt/noVNC" ]; then
  echo ">>> Kloning noVNC..."
  sudo git clone https://github.com/novnc/noVNC.git /opt/noVNC
  sudo ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html
else
  echo ">>> noVNC sudah ada di /opt/noVNC, lewati kloning."
fi

echo "=================================================="
echo ">>> BAGIAN 2: KONFIGURASI XFCE & VNC"
echo "=================================================="

# 1. Atur password VNC untuk user runner
echo ">>> Mengatur password VNC untuk user: $USERNAME..."
mkdir -p /home/${USERNAME}/.vnc
# Membuat file passwd VNC (menggunakan password dari variabel lingkungan)
echo ${PASSWORD} | vncpasswd -f > /home/${USERNAME}/.vnc/passwd
chmod 600 /home/${USERNAME}/.vnc/passwd
sudo chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.vnc

# 2. Atur start-up XFCE untuk VNC
echo ">>> Mengatur start-up XFCE..."
echo "startxfce4" > /home/${USERNAME}/.xsession
sudo chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsession


echo "=================================================="
echo ">>> BAGIAN 3: START LAYANAN (TAILSCALE, VNC, NOVNC)"
echo "=================================================="

# --- KONFIGURASI TAILSCALE ---
echo ">>> Memulai Tailscale..."
# --reset untuk memastikan konfigurasi bersih jika runner digunakan kembali
sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${TAILSCALE_HOSTNAME}" --reset --accept-dns=false

# Port VNC Internal (biasanya 5900 + display number, yaitu 5901 untuk :1)
VNC_REAL_PORT=5901

# 1. Mulai server VNC pada display :1 (pastikan binding di localhost)
echo ">>> Memulai VNC server pada :1 di localhost..."
# Jalankan vncserver sebagai user non-root
sudo -u ${USERNAME} vncserver :1 -geometry 700x800 -depth 24 -localhost

# 2. Start socat (Port Forwarding VNC Mentah)
# Meneruskan koneksi VNC dari antarmuka mana pun (termasuk Tailscale) ke server VNC di localhost:5901.
echo ">>> Memulai VNC raw TCP forwarding (socat)..."
nohup socat TCP4-LISTEN:${VNC_PORT},fork TCP4:localhost:${VNC_REAL_PORT} &

# 3. Mulai websockify (proxy VNC ke WebSocket - untuk noVNC)
echo ">>> Memulai noVNC websockify..."
nohup websockify --web=/opt/noVNC ${WEBSOCKET_PORT} localhost:${VNC_REAL_PORT} &

# 4. Dapatkan IP Tailscale
TAILSCALE_IP=$(tailscale ip -4 | head -n1)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "ERROR: Gagal mendapatkan IP Tailscale."
    exit 1
fi

echo "=================================================="
echo "=== INFO KONEKSI AKHIR ==="
echo "=================================================="
echo "USERNAME: ${USERNAME}"
echo "PASSWORD: ${PASSWORD}"
echo
echo "Klien VNC (TigerVNC/RealVNC):"
echo "    Alamat: ${TAILSCALE_IP}:${VNC_PORT}"
echo
echo "noVNC URL (Browser):"
echo "    http://${TAILSCALE_IP}:${WEBSOCKET_PORT}/"
echo
echo ">>> Menjaga runner tetap hidup sampai dibatalkan secara manual..."
# Jaga skrip ini tetap berjalan untuk menjaga job GitHub Actions tetap aktif.
while true; do
    sleep 300
done
