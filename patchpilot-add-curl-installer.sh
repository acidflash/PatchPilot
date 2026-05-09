#!/usr/bin/env bash
set -euo pipefail

# Run this from inside your existing patchpilot project directory.
# Example:
#   cd patchpilot
#   bash patchpilot-add-curl-installer.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/main.py" ]]; then
  echo "ERROR: Run this script from inside the patchpilot project directory."
  echo "Expected file: backend/app/main.py"
  exit 1
fi

if [[ ! -f "agent/patchpilot-agent.py" ]]; then
  echo "ERROR: Missing agent/patchpilot-agent.py"
  exit 1
fi

mkdir -p backend/app/static

cp agent/patchpilot-agent.py backend/app/static/patchpilot-agent.py
chmod 644 backend/app/static/patchpilot-agent.py

if grep -q "PATCHPILOT_CURL_INSTALLER_ROUTES" backend/app/main.py; then
  echo "[+] Installer routes already exist in backend/app/main.py"
else
  cat >> backend/app/main.py <<'PYEOF'


# PATCHPILOT_CURL_INSTALLER_ROUTES
@app.get("/agent/patchpilot-agent.py", response_class=PlainTextResponse)
def download_agent():
    with open("app/static/patchpilot-agent.py", "r", encoding="utf-8") as f:
        return PlainTextResponse(
            f.read(),
            media_type="text/x-python; charset=utf-8",
            headers={"Cache-Control": "no-store"},
        )

@app.get("/install.sh", response_class=PlainTextResponse)
def install_agent_script(request: Request):
    detected_server_url = str(request.base_url).rstrip("/")
    script = f"""#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="{detected_server_url}"
AGENT_URL="$SERVER_URL/agent/patchpilot-agent.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      SERVER_URL="$2"
      AGENT_URL="$SERVER_URL/agent/patchpilot-agent.py"
      shift 2
      ;;
    --agent-url)
      AGENT_URL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Run as root, for example:"
  echo "  curl -fsSL $SERVER_URL/install.sh | sudo bash"
  exit 1
fi

echo "[+] PatchPilot agent installer"
echo "[+] Server URL: $SERVER_URL"

export DEBIAN_FRONTEND=noninteractive

echo "[+] Installing dependencies"
apt-get update
apt-get install -y python3 ca-certificates unattended-upgrades curl

echo "[+] Installing agent"
install -d -m 700 /etc/patchpilot
curl -fsSL "$AGENT_URL" -o /usr/local/bin/patchpilot-agent
chmod 755 /usr/local/bin/patchpilot-agent

echo "[+] Enrolling client"
/usr/local/bin/patchpilot-agent --enroll --server "$SERVER_URL"

echo "[+] Creating systemd service"
cat > /etc/systemd/system/patchpilot-agent.service <<'UNIT'
[Unit]
Description=PatchPilot Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/patchpilot-agent --once
UNIT

echo "[+] Creating systemd timer"
cat > /etc/systemd/system/patchpilot-agent.timer <<'UNIT'
[Unit]
Description=Run PatchPilot Agent every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=patchpilot-agent.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now patchpilot-agent.timer

echo "[+] Running first check-in"
systemctl start patchpilot-agent.service || true

echo
echo "[+] Done."
echo "[+] Config: /etc/patchpilot/agent.json"
echo "[+] Logs:   journalctl -u patchpilot-agent.service -n 100 --no-pager"
"""
    return PlainTextResponse(
        script,
        media_type="text/x-shellscript; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )
PYEOF

  echo "[+] Added installer routes to backend/app/main.py"
fi

echo
echo "[+] Done."
echo
echo "Now rebuild backend:"
echo "  docker compose up -d --build"
echo
echo "Then install agent on a client with:"
echo "  curl -fsSL https://patch.axnet.ax/install.sh | sudo bash"
echo
echo "Alternative with explicit server:"
echo "  curl -fsSL https://patch.axnet.ax/install.sh | sudo bash -s -- --server https://patch.axnet.ax"
