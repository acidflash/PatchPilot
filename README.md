# PatchPilot

Self-hosted Ubuntu patch management MVP.

## Server install

```bash
cp .env.example .env
nano .env
docker compose up -d --build
```

Open locally:

```text
http://127.0.0.1:8080/admin
```

With Cloudflare Tunnel, expose:

```text
patch.axnet.ax        -> http://127.0.0.1:8080
patch-admin.axnet.ax  -> http://127.0.0.1:8080
```

Recommended Cloudflare rules:

```text
patch.axnet.ax:
  allow /api/v1/agent/*
  block /admin, /docs, /redoc, /openapi.json

patch-admin.axnet.ax:
  protect with Cloudflare Access
```

## Agent install

Copy the `agent` folder to an Ubuntu client and run:

```bash
cd agent
sudo ./install-agent.sh --server https://patch.axnet.ax
```

## Current MVP features

- Agent enrollment
- Machine check-in
- Update count
- Security update count, basic detection
- Reboot-required detection
- Manual jobs from UI:
  - check_updates
  - upgrade
  - security_upgrade
  - reboot
  - apt_clean
- Auto patch and auto reboot flags in DB/UI, scheduler not implemented yet

## Important security note

This MVP does not execute arbitrary commands from the server. Agents only accept fixed actions.
