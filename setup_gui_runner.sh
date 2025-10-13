#!/bin/bash
set -eo pipefail

# Skrip All-in-One untuk Instalasi dan Konfigurasi XFCE, Xvnc/TigerVNC, Xrdp, noVNC, dan Tailscale.

# Pastikan semua variabel lingkungan yang diperlukan ada
if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$TAILSCALE_AUTHKEY" || -z "$TAILSCALE_HOSTNAME" || -z "$VNC_PORT" || -z "$WEBSOCKET_PORT" ]]; then
    echo "ERROR: Beberapa variabel lingkungan yang diperlukan (USERNAME, PASSWORD, TAILSCALE_AUTHKEY, TAILSCALE_HOSTNAME, VNC_PORT, WEBSOCKET_PORT) tidak diset."
    exit 1
fi

echo "=================================================="
echo ">>> BAGIAN 1: INSTALASI DEPENDENSI (Termasuk XRDP)"
echo "=================================================="

echo ">>> Menginstal Tailscale Repository..."
# Menginstal Tailscale Repository
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo ">>> Menginstal XFCE, VNC, noVNC tools, Tailscale client, dan XRDP..."
sudo apt-get update -qq

# Paket Instalasi (Ditambah xrdp)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  xfce4 xfce4-goodies xorg dbus-x11 git python3-websockify socat \
  tigervnc-standalone-server tigervnc-common tigervnc-tools tailscale xrdp

# Kloning noVNC
if [ ! -d "/opt/noVNC" ]; then
  echo ">>> Kloning noVNC..."
  sudo git clone https://github.com/novnc/noVNC.git /opt/noVNC
  sudo ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html
else
  echo ">>> noVNC sudah ada di /opt/noVNC, lewati kloning."
fi

echo "=================================================="
echo ">>> BAGIAN 2: KONFIGURASI XFCE, VNC, & XRDP"
echo "=================================================="

# --- KONFIGURASI XFCE & VNC ---

# 1. Atur password VNC untuk user runner
echo ">>> Mengatur password VNC untuk user: $USERNAME..."
mkdir -p /home/${USERNAME}/.vnc
# Membuat file passwd VNC (menggunakan password dari variabel lingkungan)
echo ${PASSWORD} | vncpasswd -f > /home/${USERNAME}/.vnc/passwd
chmod 600 /home/${USERNAME}/.vnc/passwd
sudo chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.vnc

# 2. Atur start-up XFCE
# Skrip ini akan dipanggil oleh vncserver dan xrdp
echo "#!/bin/sh
xrdb $HOME/.Xresources
startxfce4" > /home/${USERNAME}/.xsession
sudo chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsession
chmod +x /home/${USERNAME}/.xsession # Pastikan bisa dieksekusi

# --- KONFIGURASI XRDP ---
echo ">>> Mengkonfigurasi XRDP..."

# 1. Gunakan Xvnc sebagai backend untuk Xrdp.
# Xrdp akan mengelola sesi, dan Xvnc akan menyediakan tampilan grafis.
# File startwm.sh standar harus disesuaikan untuk XFCE.
# Kita akan buat file .xsession di atas sudah cukup, tapi kita tambahkan file /etc/xrdp/startwm.sh
# untuk memastikan Xrdp menggunakan XFCE.

# Kita buat file startwm.sh di /etc/xrdp
# Ini biasanya mengarahkan ke ~/.xsession
sudo sed -i 's|#startwm=...|startwm=...|' /etc/xrdp/xrdp.ini # hapus komentar jika perlu
sudo echo "startxfce4" > /etc/xrdp/startwm.sh # Ganti skrip default dengan startxfce4
sudo chmod +x /etc/xrdp/startwm.sh

# 2. Tambahkan user ke grup ssl-cert untuk akses port RDP
# Xrdp berjalan sebagai service, ini membantu dengan izin
sudo usermod -a -G ssl-cert ${USERNAME}
sudo systemctl enable xrdp # Aktifkan service
sudo systemctl start xrdp # Mulai service

echo "=================================================="
echo ">>> BAGIAN 3: START LAYANAN (TAILSCALE, VNC, NOVNC)"
echo "=================================================="

# --- KONFIGURASI TAILSCALE ---
echo ">>> Memulai Tailscale..."
# --reset untuk memastikan konfigurasi bersih jika runner digunakan kembali
sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${TAILSCALE_HOSTNAME}" --reset --accept-dns=false

# Port RDP Standar: 3389
RDP_PORT=3389

# Port VNC Internal (biasanya 5900 + display number, yaitu 5901 untuk :1)
VNC_REAL_PORT=5901

# 1. Mulai server VNC (Xvnc) pada display :1 (pastikan binding di localhost)
echo ">>> Memulai VNC server (Xvnc) pada :1 di localhost..."
# Jalankan vncserver sebagai user non-root. Xvnc akan menyediakan sesi grafis.
# CATATAN: Dengan adanya Xrdp, vncserver ini opsional jika kamu hanya ingin RDP. 
# Tapi karena noVNC (websockify) menggunakan VNC, kita tetap jalankan.
sudo -u ${USERNAME} vncserver :1 -geometry 700x800 -depth 24 -localhost

# 2. Start socat (Port Forwarding VNC Mentah)
echo ">>> Memulai VNC raw TCP forwarding (socat) untuk Tailscale..."
nohup socat TCP4-LISTEN:${VNC_PORT},fork TCP4:localhost:${VNC_REAL_PORT} &

# 3. Mulai websockify (proxy VNC ke WebSocket - untuk noVNC)
echo ">>> Memulai noVNC websockify..."
nohup websockify --web=/opt/noVNC ${WEBSOCKET_PORT} localhost:${VNC_REAL_PORT} &

# 4. Start socat (Port Forwarding RDP Mentah)
# Meneruskan koneksi RDP dari antarmuka mana pun (termasuk Tailscale) ke server Xrdp di localhost:3389.
echo ">>> Memulai RDP raw TCP forwarding (socat) untuk Tailscale..."
nohup socat TCP4-LISTEN:${RDP_PORT},fork TCP4:localhost:${RDP_PORT} &

# 5. Dapatkan IP Tailscale
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
echo "Klien RDP (Remote Desktop, Remmina):"
echo "    Alamat: ${TAILSCALE_IP}:${RDP_PORT}"
echo "    Catatan: Xrdp akan membuat sesi XFCE baru. Gunakan username/password di atas."
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
