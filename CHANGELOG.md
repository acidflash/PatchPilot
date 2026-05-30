# Changelog

All notable changes to PatchPilot are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.6.7] — 2026-05-30 · Server 0.6.7 · Agent 0.6.7

### Fixed
- Agent: removed redundant `import hashlib as _hashlib` inside `self_update_agent` — `hashlib` is already imported at module level
- Agent: `shutil` moved to top-level imports
- Agent: `http_json` now catches `URLError` (network errors) in addition to `HTTPError`, with a clear error message
- Agent: response decoding uses explicit `utf-8` with `errors='replace'` instead of implicit default
- Agent: fallback status check uses `is not None` instead of truthiness to avoid incorrect behaviour on empty dict

---

## [0.6.6] — 2026-05-30 · Server 0.6.5 · Agent 0.6.5

### Changed
- `deploy.sh` no longer runs `git push` — push is done separately before deploying

---

## [0.6.5] — 2026-05-30 · Server 0.6.5 · Agent 0.6.5

### Changed
- Bumped `APP_VERSION` and `AGENT_VERSION` to 0.6.5 to reflect all changes since 0.6.0

---

## [0.6.4] — 2026-05-30 · Server 0.6.0 · Agent 0.6.0

### Fixed
- Caddy now correctly expands environment variables in site addresses using `envsubst` and a custom entrypoint script — Caddy's native `{env.VAR}` syntax does not work for site addresses
- Agent hostname block is only added to the generated Caddyfile if `CADDY_AGENT_HOSTNAME` is set, preventing a parse error on empty values

### Changed
- Caddy is now built from a custom `caddy/Dockerfile` (based on `caddy:2-alpine` with `gettext` for `envsubst`)
- `Caddyfile` replaced by `Caddyfile.template` with `${VAR}` placeholders processed at container startup

---

## [0.6.3] — 2026-05-30 · Server 0.6.0 · Agent 0.6.0

### Changed
- Caddy configuration now reads `CADDY_ADMIN_HOSTNAME`, `CADDY_EMAIL`, and `CADDY_ACME_CA` from `.env` instead of being hardcoded in `Caddyfile`
- Added `env_file: .env` to the Caddy service in `docker-compose.yml`
- Added Caddy variables to `.env.example` with documentation

---

## [0.6.2] — 2026-05-30 · Server 0.6.0 · Agent 0.6.0

### Changed
- Expanded Deployment section in README with step-by-step instructions: prerequisites, `.env` reference, Caddy configuration, agent installation, agent approval flow, and ongoing deploys via `deploy.sh`

---

## [0.6.1] — 2026-05-30 · Server 0.6.0 · Agent 0.6.0

### Added
- GPL-3.0 `LICENSE` file with copyright notice
- GPL-3.0 copyright headers in all source files
- `deploy.env.example` — template for local deploy configuration

### Changed
- `deploy.sh` now reads `DEPLOY_HOST` and `DEPLOY_DIR` from `deploy.env` (gitignored) instead of hardcoded values
- All config files sanitized for public release: replaced private hostnames, IPs, and domains with `example.com` placeholders
- `.claude/` added to `.gitignore`

### Security
- Removed accidentally committed `.env` with live credentials from git history
- Scrubbed all private hostnames, IPs, and personal paths from full git history
- Repository made public on GitHub

---

## [0.6.0] — 2026-05-29 · Server 0.6.0 · Agent 0.6.0

### Changed
- Translated README.md and INTERNALS.md to English

### Added
- `deploy.sh` script for one-command deploy: push local commits, pull on server, rebuild container
- CHANGELOG.md

---

## [0.5.1] — 2026-05-29 · Server 0.5.1 · Agent 0.6.0

### Added
- Auto-reload for the Fleet table without full page refresh
- Auto-reload for Job operations without full page refresh

### Changed
- Improved animations and touch handling in the admin UI

---

## [0.5.0] — 2026-05-18 · Server 0.5.0 · Agent 0.6.0

### Added
- `AGENT_INTERNAL_HOSTNAME` env var for correct real IP detection behind a reverse proxy
- "Add agent" button with installation modal in the fleet section
- `auto_patch` and `auto_reboot` flags per machine, configurable from the admin UI
- Cache-based update check and schedule filtering in the check/patch logic

### Fixed
- Client IP now read from `X-Forwarded-For` instead of `request.client.host`
- IPv4-mapped IPv6 addresses (`::ffff:x.x.x.x`) stripped and shown as plain IPv4 in the asset column
- `self_update_agent`: cross-device rename fixed (temp file now written on the same filesystem as the target); `hashlib` scoping bug fixed
- Server timezone mounted into the backend container so schedules fire at the correct local time

### Security
- Bumped Jinja2 3.1.5 → 3.1.6 (CVE-2025-27516)
- Bumped python-multipart 0.0.20 → 0.0.27 (security: header limits)

---

## [0.4.0] — 2026-05-09 · Server 0.4.5 · Agent 0.5.0

### Added
- Full enterprise UI redesign: dark theme, sticky sidebar, KPI cards, real-time search
- Complete test suite: 64 tests covering API, security, and agent logic
- `SECURITY.md` security policy
- Dependabot configuration

---

## [0.3.0] — 2026-05-09 · Server 0.4.5 · Agent 0.5.0

### Added
- Full documentation of all environment variables in `.env.example`

### Fixed
- Multiple security and bug fixes across backend, agent, and installer

### Security
- Hardened backend, agent, and install script

---

## [0.1.0] — 2026-05-09 · Server 0.4.5 · Agent 0.5.0

### Added
- Initial release
- Agent: enrollment, check-in, job execution, self-update, systemd service
- Server: FastAPI backend, PostgreSQL, admin UI, agent API
- Security: per-agent bcrypt tokens, CSRF protection, host-based routing, rate limiting
- Scheduler: automated patch windows with timezone support and approval flow
- Discord notifications
- Docker Compose deployment
