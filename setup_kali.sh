#!/bin/bash
# setup_kali.sh

# One-time setup script that prepares the Kali machine for deployment.
# Run this once on a fresh Kali instance before running deploy.sh.
# Handles all dependency installation, repo cloning, TLS certificate
# generation, and automatic IP detection so the operator never needs
# to manually edit any configuration files.
#
# Usage:
#   chmod +x setup_kali.sh
#   ./setup_kali.sh
#
# After this script completes:
#   1. Run the WinRM one-liner on the Windows target
#   2. Run: ./deploy.sh <WINDOWS_IP>

# ── Install system dependencies ───────────────────────────────────────────────
# ansible     - orchestration tool that deploys scripts to Windows targets
# git         - required to clone the repo and pull updates during competition
# nmap        - network scanner useful for discovering targets on the OpenStack network
# -y flag automatically confirms all apt prompts so the script runs without
# operator input.
echo "[*] Installing dependencies..."
sudo apt update && sudo apt install ansible git nmap -y

# pywinrm  - Python library that Ansible uses under the hood to speak WinRM
#            to Windows targets. Without this win_* Ansible modules fail.
# flask    - Python web framework used by c2_server.py to serve the beacon
#            and issue endpoints over HTTPS.
# --break-system-packages is required on Kali 2025 which uses PEP 668
# externally managed Python environments that block pip installs by default.
pip install pywinrm flask --break-system-packages

# Installs the ansible.windows collection which provides all the win_*
# modules used in deploy.yml such as win_copy, win_template, win_service,
# win_file and win_shell. Without this collection the playbook fails
# immediately with module not found errors.
ansible-galaxy collection install ansible.windows

# ── Clone the red team tool repo ─────────────────────────────────────────────
# Clones the repo into the home directory of the current user.
# cd into the repo immediately so all subsequent commands run from
# the correct working directory where payload.ps1 and other files live.
echo "[*] Cloning repo..."
cd ~
git clone https://github.com/BSparacio/CDT_Red_Team_Tool.git
cd CDT_Red_Team_Tool

# ── Generate TLS certificate for C2 server ───────────────────────────────────
# The C2 server requires a TLS certificate to serve HTTPS traffic.
# We generate a self-signed certificate valid for 30 days which covers
# the duration of any CTF competition. The certificate does not need to
# be trusted by a CA since the Windows beacon bypasses certificate
# validation using the TrustAll policy class in payload.ps1.
#
# Flags explained:
#   -x509          generate a self-signed certificate instead of a CSR
#   -newkey rsa:4096  generate a new 4096-bit RSA private key
#   -keyout key.pem   write the private key to key.pem
#   -out cert.pem     write the certificate to cert.pem
#   -days 30          certificate is valid for 30 days
#   -nodes            do not encrypt the private key with a passphrase
#                     so c2_server.py can load it without prompting
#   -subj             provide certificate subject fields non-interactively
#                     so the script runs without operator input
echo "[*] Generating TLS certificate..."
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 30 -nodes \
    -subj "/C=US/ST=NY/L=Rochester/O=RIT/CN=c2server"


# ── Detect Kali IP address ────────────────────────────────────────────────────
# Parses the output of ip a to find the Kali machine's IP address on the
# OpenStack network. The regex matches any IP starting with 100. which is
# the address range used by the CyberRange OpenStack network.
# grep -oP enables Perl-compatible regex with -o outputting only the match.
# The lookbehind (?<=inet ) matches only IPs that follow the word inet
# in the ip a output so we do not accidentally capture subnet masks.
# head -1 takes only the first match in case multiple interfaces match.
echo "[*] Detecting Kali IP..."
KALI_IP=$(ip a | grep -oP '(?<=inet )100\.\d+\.\d+\.\d+' | head -1)
echo "[*] Kali IP detected as: $KALI_IP"

# ── Update payload.ps1 with detected Kali IP ─────────────────────────────────
# Uses sed to find and replace the $C2 line in payload.ps1 with the
# detected Kali IP. The | delimiter is used instead of the standard /
# because the replacement string contains forward slashes in the URL
# which would break a / delimited sed expression.
# The regex matches the entire $C2 = "https://anything" line and replaces
# it with the correct IP. This works whether the file contains the
# <KALI_IP> placeholder from the repo or a stale IP from a previous run.
echo "[*] Updating payload.ps1 with Kali IP..."
sed -i "s|\$C2.*=.*\"https://.*\"|\$C2      = \"https://$KALI_IP\"|" payload.ps1

# ── Setup complete ────────────────────────────────────────────────────────────
echo ""
echo "[+] Kali setup complete."
echo "[+] Kali IP: $KALI_IP"
echo ""
echo "Next steps:"
echo "  1. Run WinRM setup on the Windows target"
echo "  2. Run: ./deploy.sh <WINDOWS_IP>"