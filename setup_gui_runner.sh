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
echo ${PASSWORD} | vncpasswd -f > /home/${USERNAME}/.vnc/passwd
chmod 600 /home/${USERNAME}/.vnc/passwd
sudo chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.vnc

# 2. Atur start-up XFCE
echo "#!/bin/sh
xrdb $HOME/.Xresources
startxfce4" > /home/${USERNAME}/.xsession
sudo chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xsession
chmod +x /home/${USERNAME}/.xsession

# --- KONFIGURASI XRDP ---
echo ">>> Mengkonfigurasi XRDP..."
sudo echo "startxfce4" > /etc/xrdp/startwm.sh
sudo chmod +x /etc/xrdp/startwm.sh
sudo usermod -a -G ssl-cert ${USERNAME}

# Pastikan XRDP dimulai SEBELUM kita menjalankan socat.
echo ">>> Memulai service XRDP..."
sudo systemctl enable xrdp
sudo systemctl start xrdp

echo "=================================================="
echo ">>> BAGIAN 3: START LAYANAN (TAILSCALE, VNC, NOVNC)"
echo "=================================================="

# --- KONFIGURASI TAILSCALE ---
echo ">>> Memulai Tailscale..."
sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${TAILSCALE_HOSTNAME}" --reset --accept-dns=false

# Port INTERNAL standar yang sudah dipakai oleh layanan:
VNC_REAL_PORT=5901 # Port internal vncserver :1
RDP_REAL_PORT=3389 # Port internal xrdp

# Port yang akan didengarkan oleh socat di antarmuka Tailscale:
VNC_PORT_LISTEN=${VNC_PORT:-5902}       # Default: 5902 (diganti dari 5901)
RDP_PORT_LISTEN=${RDP_PORT:-3390}       # Default: 3390 (diganti dari 3389)
WEBSOCKET_PORT_LISTEN=${WEBSOCKET_PORT:-6080}

# 1. Mulai server VNC (Xvnc) pada display :1 (hanya di localhost)
# Ini menggunakan VNC_REAL_PORT=5901
echo ">>> Memulai VNC server (Xvnc) pada :1 di localhost:${VNC_REAL_PORT}..."
sudo -u ${USERNAME} vncserver :1 -geometry 700x800 -depth 24 -localhost

# 2. Start socat (Port Forwarding VNC Mentah)
# Teruskan dari VNC_PORT_LISTEN ke VNC_REAL_PORT (5901)
echo ">>> Memulai VNC raw TCP forwarding (socat) dari ${VNC_PORT_LISTEN} ke localhost:${VNC_REAL_PORT}..."
nohup socat TCP4-LISTEN:${VNC_PORT_LISTEN},fork TCP4:localhost:${VNC_REAL_PORT} &

# 3. Mulai websockify (proxy VNC ke WebSocket - untuk noVNC)
# Teruskan dari WEBSOCKET_PORT_LISTEN ke VNC_REAL_PORT (5901)
echo ">>> Memulai noVNC websockify dari ${WEBSOCKET_PORT_LISTEN} ke localhost:${VNC_REAL_PORT}..."
nohup websockify --web=/opt/noVNC ${WEBSOCKET_PORT_LISTEN} localhost:${VNC_REAL_PORT} &

# 4. Start socat (Port Forwarding RDP Mentah)
# Teruskan dari RDP_PORT_LISTEN ke RDP_REAL_PORT (3389)
echo ">>> Memulai RDP raw TCP forwarding (socat) dari ${RDP_PORT_LISTEN} ke localhost:${RDP_REAL_PORT}..."
nohup socat TCP4-LISTEN:${RDP_PORT_LISTEN},fork TCP4:localhost:${RDP_REAL_PORT} &

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
echo "    Alamat: ${TAILSCALE_IP}:${RDP_PORT_LISTEN}"
echo
echo "Klien VNC (TigerVNC/RealVNC):"
echo "    Alamat: ${TAILSCALE_IP}:${VNC_PORT_LISTEN}"
echo
echo "noVNC URL (Browser):"
echo "    http://${TAILSCALE_IP}:${WEBSOCKET_PORT_LISTEN}/"
echo
