#!/usr/bin/env bash
# Copyright (C) 2026 Jonas Byström <jonas@lediga.st>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

# Copy deploy.env.example to deploy.env and fill in your values.
# deploy.env is gitignored and never committed.
if [[ -f "$(dirname "$0")/deploy.env" ]]; then
  # shellcheck source=/dev/null
  source "$(dirname "$0")/deploy.env"
fi

: "${DEPLOY_HOST:?Set DEPLOY_HOST in deploy.env or the environment}"
: "${DEPLOY_DIR:?Set DEPLOY_DIR in deploy.env or the environment}"

echo "[+] Pushing to remote..."
git push

echo "[+] Deploying on $DEPLOY_HOST..."
ssh "$DEPLOY_HOST" "cd $DEPLOY_DIR && git pull && docker compose up --build -d"

echo "[+] Done."
