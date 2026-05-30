#!/usr/bin/env bash
# Copyright (C) 2026 Jonas Byström <jonas@lediga.st>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

HOST="192.168.1.100"
REMOTE_DIR="/opt/patchpilot"

echo "[+] Pushing to remote..."
git push

echo "[+] Deploying on $HOST..."
ssh "$HOST" "cd $REMOTE_DIR && git pull && docker compose up --build -d"

echo "[+] Done."
