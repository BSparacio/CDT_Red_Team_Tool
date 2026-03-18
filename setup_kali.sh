#!/bin/bash
# setup_kali.sh - Run once on fresh Kali to set everything up

echo "[*] Installing dependencies..."
sudo apt update && sudo apt install ansible git nmap -y
pip install pywinrm flask --break-system-packages
ansible-galaxy collection install ansible.windows

echo "[*] Cloning repo..."
cd ~
git clone https://github.com/BSparacio/CDT_Red_Team_Tool.git
cd CDT_Red_Team_Tool

echo "[*] Generating TLS certificate..."
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 30 -nodes \
    -subj "/C=US/ST=NY/L=Rochester/O=RIT/CN=c2server"

echo "[*] Detecting Kali IP..."
KALI_IP=$(ip a | grep -oP '(?<=inet )100\.\d+\.\d+\.\d+' | head -1)
echo "[*] Kali IP detected as: $KALI_IP"

echo "[*] Updating payload.ps1 with Kali IP..."
sed -i "s|\$C2.*=.*\"https://.*\"|\$C2      = \"https://$KALI_IP\"|" payload.ps1

echo ""
echo "[+] Kali setup complete."
echo "[+] Kali IP: $KALI_IP"
echo ""
echo "Next steps:"
echo "  1. Run WinRM setup on the Windows target"
echo "  2. Run: ./deploy.sh <WINDOWS_IP>"