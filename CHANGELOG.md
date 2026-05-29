# Changelog

All notable changes to PatchPilot are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.6.0] — 2026-05-29

### Changed
- Translated README.md and INTERNALS.md to English

### Added
- `deploy.sh` script for one-command deploy: push local commits, pull on server, rebuild container
- CHANGELOG.md

---

## [0.5.1] — 2026-05-29

### Added
- Auto-reload for the Fleet table without full page refresh
- Auto-reload for Job operations without full page refresh

### Changed
- Improved animations and touch handling in the admin UI

---

## [0.5.0] — 2026-05-18

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

## [0.4.0] — 2026-05-09

### Added
- Full enterprise UI redesign: dark theme, sticky sidebar, KPI cards, real-time search
- Complete test suite: 64 tests covering API, security, and agent logic
- `SECURITY.md` security policy
- Dependabot configuration

---

## [0.3.0] — 2026-05-09

### Added
- Full documentation of all environment variables in `.env.example`

### Fixed
- Multiple security and bug fixes across backend, agent, and installer

### Security
- Hardened backend, agent, and install script

---

## [0.1.0] — 2026-05-09

### Added
- Initial release
- Agent: enrollment, check-in, job execution, self-update, systemd service
- Server: FastAPI backend, PostgreSQL, admin UI, agent API
- Security: per-agent bcrypt tokens, CSRF protection, host-based routing, rate limiting
- Scheduler: automated patch windows with timezone support and approval flow
- Discord notifications
- Docker Compose deployment
