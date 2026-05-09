#!/usr/bin/env bash
set -euo pipefail

SERVER_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      SERVER_URL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$SERVER_URL" ]]; then
  echo "Usage: sudo ./install-agent.sh --server https://patch.example.com"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

apt-get update
apt-get install -y python3 ca-certificates unattended-upgrades

install -d -m 700 /etc/patchpilot
install -m 755 ./patchpilot-agent.py /usr/local/bin/patchpilot-agent

# Verify agent integrity against server
AGENT_META=$(curl -fsSL "$SERVER_URL/api/v1/agent/latest" 2>/dev/null || true)
EXPECTED_SHA=$(echo "$AGENT_META" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha256',''))" 2>/dev/null || true)
if [ -n "$EXPECTED_SHA" ]; then
  ACTUAL_SHA=$(sha256sum /usr/local/bin/patchpilot-agent | cut -d' ' -f1)
  if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "ERROR: Agent integrity check failed. Expected $EXPECTED_SHA, got $ACTUAL_SHA"
    rm -f /usr/local/bin/patchpilot-agent
    exit 1
  fi
  echo "Agent integrity verified."
fi

/usr/local/bin/patchpilot-agent --enroll --server "$SERVER_URL"

cat > /etc/systemd/system/patchpilot-agent.service <<'UNIT'
[Unit]
Description=PatchPilot Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/patchpilot-agent --once
UNIT

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

echo "PatchPilot agent installed and enrolled."
