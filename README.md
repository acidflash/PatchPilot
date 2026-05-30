# PatchPilot

Self-hosted patch management for Ubuntu servers. Agents on each machine report status, receive commands, and perform controlled updates — all manageable from a web-based control center.

---

## What is PatchPilot?

PatchPilot consists of two parts: a **server** (the control center) and an **agent** (runs on each Ubuntu machine to be managed). The agent talks to the server — not the other way around. This means no ports need to be opened toward the managed machines.

---

## Features

### Agent — installed on each Ubuntu server

**Enrollment**
The agent registers itself with the server on first start. It generates a unique machine ID based on hostname + random suffix and stores it locally. The server issues a signed bearer token used in all subsequent communication. Re-enrollment is handled automatically — if the machine is already registered, the agent exits cleanly without an error code.

**Check-in**
The agent checks in with the server every five minutes and reports:
- Hostname, OS version, kernel version, agent version
- Number of available updates (total and security-related)
- Whether a reboot is required after a previous update
- List of packages with available versions, including a flag for CVE-related packages

**Job execution**
The server can queue commands that the agent picks up at the next check-in. The agent reports status (started → done) and returns the exit code and text output. Allowed commands are hardcoded — the agent does not accept arbitrary commands from the server.

Allowed jobs:
| Command | What it does |
|---|---|
| `check_updates` | Runs `apt-get update` and counts available updates |
| `upgrade` | Full `apt-get upgrade` |
| `security_upgrade` | Upgrades only CVE-flagged packages |
| `apt_clean` | Clears the APT cache |
| `self_update` | Downloads new agent version from the server, verifies SHA256 hash, and replaces itself atomically |
| `reboot` | Reboots the machine |

**Self-update**
The agent can update itself via the server. It downloads the new version, verifies the SHA256 checksum against the server's manifest, writes it to a temporary file *on the same filesystem* as the existing agent file, and then atomically swaps it using `rename()` — a partially written file can never be activated.

**Persistence**
The agent is installed as a `systemd` service and starts automatically on reboot. Configuration (server URL, token, machine ID) is stored in `/etc/patchpilot/agent.json`.

---

### Server — the control center

**Web-based control center (Admin UI)**
An enterprise-oriented dark interface with sticky sidebar, KPI cards, and real-time filtering. Accessible via the browser. Does not require direct access to the managed machines.

Includes:
- **Fleet view** — all registered agents with status (online/stale/offline/disabled), patch exposure, CVE count, groups, and last check-in. Real-time searchable.
- **KPI cards** — total agent count, number with security exposure, number requiring reboot, job queue status
- **Job view** — all completed and ongoing jobs with output, exit codes, and timestamps
- **Groups** — organize machines into logical groups (e.g. prod servers, staging)
- **Schedules** — automated patch windows linked to a machine or group, with day, time, and timezone
- **Package exposure** — all reported packages with available upgrades, CVE-flagged ones marked separately
- **Audit log** — logging of administrative events and agent activity

**Agent API**
REST API that agents communicate with. Separated from the admin interface via host-based routing — one public hostname for agents, one internal for admin. Agents authenticate with per-machine bearer tokens.

Endpoints:
- `POST /api/v1/agent/enroll` — register new machine
- `POST /api/v1/agent/checkin` — report status and fetch pending jobs
- `POST /api/v1/agent/jobs/{id}/started` — mark job as started
- `POST /api/v1/agent/jobs/{id}/result` — report outcome
- `GET  /api/v1/agent/latest` — agent's latest version and SHA256
- `GET  /agent/patchpilot-agent.py` — download the agent file
- `GET  /install.sh` — generated install script with built-in SHA256 verification

**Scheduler**
A background process checks every minute whether any schedule should activate. It automatically creates jobs for the correct machines or groups based on day, time, and timezone. Supports approval requirements — the job is queued but waits for manual approval in the UI before being sent to the agent.

**Agent approval flow**
New agents can require manual approval before they are allowed to execute jobs. The administrator approves or rejects in the UI. Can be disabled to auto-approve all new agents.

---

### Security

**Authentication**
- Each agent has a unique bearer token (prefix `pp_agent_` + 32 random bytes, URL-safe base64). The token is stored only as a bcrypt hash in the database.
- The admin interface is protected with HTTP Basic Auth via the `ADMIN_PASSWORD` environment variable.

**CSRF protection**
All POST forms in the admin interface include a CSRF token that is validated server-side. The token is HMAC-SHA256 of a secret key + current hour, valid for up to two hours. Automatically injected into all forms via JavaScript — no manual handling required in the forms.

**XSS protection**
Jinja2 HTML-escapes all template variables automatically. Confirmation dialogs (e.g. "Delete agent?") use `data-confirm` attributes with a generic text — not dynamic strings embedded in JavaScript code, which would open up for XSS.

**Host-based routing**
The agents' public endpoint and the admin interface are exposed on different hostnames. If a request to the admin hostname hits the agent API, or vice versa, a 404 is returned. This means the admin interface never needs to be publicly accessible.

**Rate limiting**
The enrollment endpoint allows a maximum of 10 registrations per IP address per hour. Protects against automated attempts to register large numbers of fake agents.

**Secure self-update**
The agent verifies the SHA256 checksum of the downloaded agent file before replacing itself. The temp file is written on the same filesystem as the target file to guarantee atomic renaming — no risk of a half-corrupt agent file on power failure.

**Package validation**
The server accepts a maximum of 500 packages per check-in. Job actions are validated against a hardcoded allowlist — the server can never queue an arbitrary shell command.

---

## Tech stack

| Component | Technology |
|---|---|
| Server runtime | Python 3.11, FastAPI, Uvicorn |
| Database | PostgreSQL (production), SQLite (tests) |
| ORM | SQLAlchemy 2.0 |
| Templates | Jinja2 |
| Scheduler | APScheduler |
| Authentication | bcrypt via passlib, HMAC-SHA256 |
| Agent | Python 3 stdlib only (no external dependencies) |
| Reverse proxy | Caddy |
| Container | Docker + Docker Compose |
| Tests | pytest, 64 tests (API, security, agent logic) |

---

## Deployment

### Prerequisites

- Docker and Docker Compose
- Git
- A Linux server (Ubuntu/Debian recommended)
- A domain name, or access via LAN/Cloudflare Tunnel

---

### 1. Clone and configure

```bash
git clone https://github.com/acidflash/PatchPilot.git
cd PatchPilot
cp .env.example .env
```

Edit `.env` and fill in the required values:

| Variable | Description |
|---|---|
| `POSTGRES_PASSWORD` | Database password — use a long random string |
| `APP_SECRET` | Secret for CSRF signing — use a long random string |
| `PUBLIC_AGENT_URL` | Public URL agents use to reach the server, e.g. `https://patch.example.com` |
| `AGENT_PUBLIC_HOSTNAME` | Hostname for the agent-facing endpoint (same as above without `https://`) |
| `ADMIN_INTERNAL_HOSTNAMES` | Comma-separated hostnames for the admin UI, e.g. `patch-admin.example.com,localhost` |
| `ADMIN_PASSWORD` | Password for the admin dashboard (HTTP Basic Auth) |

Optional:

| Variable | Description |
|---|---|
| `DISCORD_WEBHOOK_URL` | Discord webhook URL for alerts |
| `CLOUDFLARED_TOKEN` | Cloudflare Tunnel token (if using Cloudflare) |
| `PATCHPILOT_AUTO_APPROVE_AGENTS` | Set to `true` to auto-approve new agents (default: `false`) |
| `PATCHPILOT_AUTO_AGENT_UPDATE` | Set to `true` to auto-update agents when a new version is available (default: `false`) |

---

### 2. Configure Caddy

Edit `caddy/Caddyfile` to match your hostnames:

```
patch.example.com {
    reverse_proxy backend:8080
}

patch-admin.example.com {
    reverse_proxy backend:8080
}
```

For Let's Encrypt (public server), remove the `acme_ca*` lines from the global block. For a private CA, point `acme_ca` and `acme_ca_root` at your CA.

---

### 3. Start the server

```bash
docker compose up -d --build
```

The admin interface is available at `https://patch-admin.example.com/admin` (or `http://localhost:8080/admin` if accessed directly).

---

### 4. Install the agent on an Ubuntu machine

**One-liner (recommended):**

```bash
curl -fsSL https://patch.example.com/install.sh | sudo bash -s -- --server https://patch.example.com
```

The install script downloads the agent from the server, verifies its SHA256 checksum, enrolls it, and installs a systemd timer that runs every 5 minutes.

**Manual install (if the machine can't reach the server directly during install):**

```bash
# Download install script and agent manually, then:
sudo ./agent/install-agent.sh --server https://patch.example.com
```

---

### 5. Approve the agent

If `PATCHPILOT_AUTO_APPROVE_AGENTS=false` (the default), new agents appear as **pending** in the admin UI under Fleet. Click **Approve** to allow the agent to receive jobs.

---

### Ongoing deploys

Copy `deploy.env.example` to `deploy.env` and fill in your server details:

```bash
cp deploy.env.example deploy.env
# Set DEPLOY_HOST and DEPLOY_DIR in deploy.env
```

Then deploy with:

```bash
./deploy.sh
```

This pushes local commits, pulls on the remote server, and rebuilds the container.

---

## Security architecture in brief

```
Ubuntu machine                  Server (internal/Cloudflare Tunnel)
┌──────────────────┐            ┌──────────────────────────────────┐
│ patchpilot-agent │ ──HTTPS──► │ /api/v1/agent/*  (public)        │
│ (systemd service)│ ◄──jobs─── │                                  │
└──────────────────┘            │ /admin           (internal only)  │
                                └──────────────────────────────────┘
```

The agent always initiates communication. No incoming connections are required to the managed machines.
