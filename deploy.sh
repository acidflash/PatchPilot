#!/usr/bin/env bash
set -euo pipefail

HOST="192.168.1.100"
REMOTE_DIR="/opt/patchpilot"

echo "[+] Pushing to remote..."
git push

echo "[+] Deploying on $HOST..."
ssh "$HOST" "cd $REMOTE_DIR && git pull && docker compose up --build -d"

echo "[+] Done."
