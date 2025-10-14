#!/bin/bash
set -eo pipefail

# Skrip All-in-One untuk Instalasi dan Konfigurasi XFCE, Xvnc/TigerVNC, Xrdp, noVNC, dan Tailscale.

# Variabel Hostname Statis (menghilangkan github.run_id)
TAILSCALE_STATIC_HOSTNAME="gh-xfce"

# Pastikan semua variabel lingkungan yang diperlukan ada
if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$TAILSCALE_AUTHKEY" ]]; then
    echo "ERROR: Beberapa variabel lingkungan yang diperlukan (USERNAME, PASSWORD, TAILSCALE_AUTHKEY) tidak diset."
    exit 1
fi

echo "=================================================="
echo ">>> BAGIAN 1: INSTALASI DEPENDENSI (Optimalisasi Cache APT)"
echo "=================================================="

# --- INSTALASI TAILSCALE REPOSITORY SECARA MANUAL UNTUK CACHING ---
echo ">>> Menambahkan Tailscale GPG key dan Repository ke APT..."

# Pasang lsb-release dan gpg (sering diperlukan di runner baru)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  lsb-release gpg

# Dapatkan nama kode OS secara dinamis (misalnya 'noble')
UBUNTU_CODENAME=$(lsb-release -cs)
echo "Dideteksi Ubuntu Codename: $UBUNTU_CODENAME"

# 1. Tambahkan GPG key resmi Tailscale dan simpan di lokasi standar
# Menggunakan opsi 'dearmor' untuk mengkonversi key ke format yang dapat dibaca oleh APT
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg

# 2. Tambahkan repo ke sources.list.d menggunakan nama kode OS yang benar
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${UBUNTU_CODENAME} main" | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null

# --- LANJUT KE LANGKAH INSTALASI APT ---
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
echo ">>> Mengatur password VNC untuk user: $USERNAME..."
mkdir -p /home/${USERNAME}/.vnc
echo ${PASSWORD} | vncpasswd -f > /home/${USERNAME}/.vnc/passwd
chmod 600 /home/${USERNAME}/.vnc/passwd
sudo chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.vnc

echo ">>> Mengatur start-up XFCE..."
echo "#!/bin/sh
xrdb $HOME/.Xresources
startxfce4" > /home/${USERNAME}/.xsession
sudo chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsession
chmod +x /home/${USERNAME}/.xsession

# --- KONFIGURASI XRDP ---
echo ">>> Mengkonfigurasi XRDP dan memulai service..."
sudo echo "startxfce4" > /etc/xrdp/startwm.sh
sudo chmod +x /etc/xrdp/startwm.sh
sudo usermod -a -G ssl-cert ${USERNAME}
sudo systemctl enable xrdp
sudo systemctl start xrdp

echo "=================================================="
echo ">>> BAGIAN 3: START LAYANAN (TAILSCALE, VNC, XRDP, HTTPS)"
echo "=================================================="

# --- KONFIGURASI TAILSCALE ---
echo ">>> Memulai Tailscale dengan hostname statis ${TAILSCALE_STATIC_HOSTNAME} dan rute diaktifkan..."
sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${TAILSCALE_STATIC_HOSTNAME}" --reset --accept-dns=false --accept-routes

# Port INTERNAL standar yang sudah dipakai oleh layanan:
VNC_REAL_PORT=5901 
RDP_REAL_PORT=3389

# Port yang akan didengarkan oleh socat/serve:
VNC_PORT_LISTEN=${VNC_PORT:-5902}       # Tailscale TCP ke 5901
RDP_PORT_LISTEN=${RDP_PORT:-3390}       # Tailscale TCP ke 3389

# 1. Mulai server VNC (Xvnc)
echo ">>> Memulai VNC server (Xvnc) pada :1 di localhost:${VNC_REAL_PORT}..."
sudo -u ${USERNAME} vncserver :1 -geometry 700x800 -depth 24 -localhost

# 2. Start socat (Port Forwarding VNC Mentah)
echo ">>> Memulai VNC raw TCP forwarding (socat) dari ${VNC_PORT_LISTEN} ke localhost:${VNC_REAL_PORT}..."
nohup socat TCP4-LISTEN:${VNC_PORT_LISTEN},fork TCP4:localhost:${VNC_REAL_PORT} &

# 3. Start socat (Port Forwarding RDP Mentah)
echo ">>> Memulai RDP raw TCP forwarding (socat) dari ${RDP_PORT_LISTEN} ke localhost:${RDP_REAL_PORT}..."
nohup socat TCP4-LISTEN:${RDP_PORT_LISTEN},fork TCP4:localhost:${RDP_REAL_PORT} &

# 4. KONFIGURASI DAN MULAI TAILSCALE SERVE (untuk noVNC di HTTPS)
WEBSOCKET_REAL_PORT=${WEBSOCKET_PORT:-6080}
echo ">>> Menjalankan websockify di background (localhost:${WEBSOCKET_REAL_PORT}) untuk Tailscale Serve..."
nohup websockify --web=/opt/noVNC ${WEBSOCKET_REAL_PORT} localhost:${VNC_REAL_PORT} &

echo ">>> Mengaktifkan Tailscale Serve untuk noVNC di HTTPS (Port 443)..."
# Tailscale Serve akan menerima koneksi HTTPS di Port 443 dan meneruskannya ke localhost:6080
sudo tailscale serve https 443 proxy http://localhost:${WEBSOCKET_REAL_PORT}
sudo tailscale set --serve &

# 5. Dapatkan IP dan Hostname Tailscale
TAILSCALE_IP=$(tailscale ip -4 | head -n1)
# Menggunakan hostname statis yang kita tentukan
TAILSCALE_FQDN="${TAILSCALE_STATIC_HOSTNAME}.${TAILNET_NAME}.ts.net" # Asumsi Tailscale FQDN format standard

# Dapatkan nama Tailnet yang sebenarnya untuk FQDN yang akurat (jika memungkinkan)
TAILNET_NAME=$(tailscale status --json | grep -o '"Self":{.*"Name":"[^"]*"' | head -n1 | cut -d'"' -f4 | cut -d'.' -f2)
if [[ -n "$TAILNET_NAME" ]]; then
    TAILSCALE_FQDN="${TAILSCALE_STATIC_HOSTNAME}.${TAILNET_NAME}.ts.net"
else
    # Jika gagal mendapatkan Tailnet name, gunakan format yang disederhanakan
    TAILSCALE_FQDN="${TAILSCALE_STATIC_HOSTNAME}.ts.net"
fi


if [[ -z "$TAILSCALE_IP" ]]; then
    echo "ERROR: Gagal mendapatkan IP Tailscale."
    exit 1
fi
clear
echo "=================================================="
echo "=== INFO KONEKSI AKHIR ==="
echo "=================================================="
echo "USERNAME: ${USERNAME}"
echo "PASSWORD: ${PASSWORD}"
echo "Hostname Tailscale: ${TAILSCALE_FQDN}"
echo
echo "Klien RDP (Remote Desktop, Remmina):"
echo "    Alamat IP: ${TAILSCALE_IP}:${RDP_PORT_LISTEN}"
echo "    Alamat Hostname: ${TAILSCALE_FQDN}:${RDP_PORT_LISTEN} (memerlukan DNS Tailscale aktif)"
echo
echo "Klien VNC (TigerVNC/RealVNC):"
echo "    Alamat IP: ${TAILSCALE_IP}:${VNC_PORT_LISTEN}"
echo "    Alamat Hostname: ${TAILSCALE_FQDN}:${VNC_PORT_LISTEN} (memerlukan DNS Tailscale aktif)"
echo
echo "noVNC URL (Browser - HTTPS aman):"
echo "    https://${TAILSCALE_FQDN}/" # HTTPS akan otomatis menggunakan Port 443
echo
