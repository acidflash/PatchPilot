# PatchPilot — Technical internal documentation

Detailed walkthrough of how each feature works and what is used under the hood.

---

## Table of contents

1. [System architecture](#system-architecture)
2. [Data model](#data-model)
3. [Agent functions](#agent-functions)
4. [Exactly what happens on the Ubuntu machine when a job runs](#exactly-what-happens-on-the-ubuntu-machine-when-a-job-runs)
5. [Server — authentication and security](#server--authentication-and-security)
6. [Server — agent API](#server--agent-api)
7. [Server — admin API](#server--admin-api)
8. [Scheduler](#scheduler)
9. [Notifications](#notifications)
10. [Install scripts](#install-scripts)
11. [Test suite](#test-suite)

---

## System architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Ubuntu machine                                                 │
│  /usr/local/bin/patchpilot-agent   (Python 3, no deps)         │
│  systemd-timer → every 5 minutes                                │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTPS  (bearer token)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Server  (Docker)                                               │
│  ┌──────────────┐   ┌────────────────────┐   ┌───────────────┐ │
│  │   Caddy      │   │  FastAPI / Uvicorn  │   │  PostgreSQL   │ │
│  │  (reverse    │──►│  Python 3.11        │──►│  SQLAlchemy   │ │
│  │   proxy)     │   │  port 8000          │   │  ORM          │ │
│  └──────────────┘   └────────────────────┘   └───────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

Caddy listens on port 80/443 and forwards to FastAPI on port 8000. FastAPI handles both the agent REST API and the admin web interface in the same process. The database is accessed exclusively via SQLAlchemy ORM — no raw SQL strings are used in application code.

---

## Data model

Six tables, defined in `backend/app/models.py` using SQLAlchemy 2.0's `Mapped` syntax (typed ORM):

### `machines`
One row per registered agent. Stores identity (`machine_id`, `hostname`), authentication (`token_hash`), system info (`os_version`, `kernel_version`, `agent_version`), patch status (`updates_available`, `security_updates_available`, `reboot_required`), behavior flags (`auto_patch`, `auto_reboot`), lifecycle status (`active`, `approved`, `approval_status`), and timestamps (`first_seen`, `last_seen`, `last_job_at`, `last_success_at`).

**Important**: `token_hash` never contains the plaintext token — only a bcrypt hash. The plaintext token exists only in the enrollment response and in the agent's config file.

### `jobs`
One row per job. Linked to a machine via `machine_id` (foreign key). Contains `action` (e.g. `upgrade`), `status` (`pending` → `running` → `success`/`failed`), `allow_reboot` flag, `output` (max 30,000 characters), `exit_code`, and three timestamps (`created_at`, `started_at`, `finished_at`).

### `groups`
Named groups with `name` (unique) and `description`. Linked to machines via `machine_groups`.

### `machine_groups`
Bridge table (`machine_id`, `group_id`) with a unique constraint on the combination — a machine can only be in the same group once.

### `package_updates`
One row per package per machine. Fully replaced on every check-in — all old rows for the machine are deleted and new ones written in (UPSERT behavior via delete+insert). Unique constraint on `(machine_id, package)`. Stores `current_version`, `candidate_version`, and `security` flag.

### `audit_logs`
Immutable log. One row per administrative event. Contains `actor` (e.g. `admin` or `agent`), `action` (e.g. `job_created`, `machine_approved`), `target_type`/`target_id`, `ip_address`, and free-text `details`.

### `schedules`
Configuration for recurring jobs. Contains target specification (`target_type`: `machine` or `group`, `target_id`), timing (`day_of_week`, `time_of_day`, `timezone`), `action`, and flags (`allow_reboot`, `require_approval`, `enabled`). `last_run_key` is a deduplication string in the format `schedule_id:YYYY-MM-DD` that prevents the same schedule from running more than once per day.

---

## Agent functions

The agent (`agent/patchpilot-agent.py`) is a single Python script with no external dependencies — only the standard library. This makes it possible to run on Ubuntu without `pip install`.

### `get_machine_id()`

```
/etc/patchpilot/machine-id
```

Reads the file if it exists. Otherwise generates an ID in the format `hostname-xxxxxxxxxxxx` where the suffix is 12 hex characters from `uuid.uuid4()`. The ID is written to the file with `chmod 600`. The file is persistent — the ID does not change if the agent is reinstalled, as long as the file remains.

### `run(cmd)`

Runs a shell command via `subprocess.run(..., shell=True)`. Sets `DEBIAN_FRONTEND=noninteractive` and `NEEDRESTART_MODE=a` in the environment so that APT never prompts interactively. Timeout is 1800 seconds by default (30 minutes). Returns `(returncode, stdout+stderr)`.

### `parse_apt_updates()`

Runs `apt list --upgradable 2>/dev/null | tail -n +2` and parses each line with regex. A typical line looks like:

```
vim/jammy 9.1.0-1ubuntu1 amd64 [upgradable from: 9.0.0-1]
```

Parsing:
- **Package name**: Everything before the first `/`
- **Candidate version**: `parts[1]` (second column)
- **Current version**: Regex `\[upgradable from:\s*([^\]]+)\]`
- **CVE flag**: Searches for the string `security` in the line (e.g. `jammy-security` in the source name)

### `apt_check_counts(packages)`

Tries to use `/usr/lib/update-notifier/apt-check` (present on most Ubuntu installations) for more accurate counting. Parses output with regex `(\d+)\s*;\s*(\d+)`. Falls back to counting the `packages` list if the tool is missing.

### `collect_status()`

Runs `apt-get update` (syncs package lists), then calls `parse_apt_updates()` and `apt_check_counts()`. Checks `/var/run/reboot-required` — this file is created by APT after an update that requires a reboot. Reads `/etc/os-release` for the OS version and `platform.release()` for the kernel version.

### `enroll(server_url)`

Calls `POST /api/v1/agent/enroll` with machine ID, hostname, agent version, OS version, and kernel version. If the server responds with `"message": "machine already enrolled"`, the agent prints an informational message and exits with exit code 0 (not an error). If the response contains `agent_token`, it is written to `/etc/patchpilot/agent.json` with `chmod 600`.

### `bootstrap_if_needed()`

Checks if `/etc/patchpilot/agent.json` exists. If not, reads `/etc/patchpilot/bootstrap.json` (set by the template install script) and runs enrollment automatically. Used for the VM template flow where enrollment does not happen at installation time but at first start of the cloned VM.

### `self_update_agent(update_url, expected_sha256)`

1. Downloads the new agent file from `update_url` via `urllib.request`
2. Checks that the file starts with `#!/usr/bin/env python3` (sanity check)
3. Computes `sha256sum` of the downloaded content
4. Compares with `expected_sha256` if provided — aborts on mismatch
5. Writes to a temp file in the **same directory** as the existing agent file (`/usr/local/bin/`) using `tempfile.NamedTemporaryFile(dir=current_path.parent)`
6. Sets `chmod 755` on the temp file
7. Creates a backup at `/usr/local/bin/patchpilot-agent.bak-{version}`
8. Calls `tmp_path.replace(current_path)` — this is an **atomic `rename()`** on Linux, never a partial file

The reason the temp file must be in the same directory (not `/tmp`): `rename()` is only atomic within the same filesystem. If the temp file is on `/tmp` and the target is on `/usr/local/bin` (which may be a different filesystem), the OS falls back to copy+delete, which is not atomic.

### `execute_job(job)`

Validates `action` against `ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}` — a job response from the server with an unknown action is ignored with an error code. Then runs the correct command based on the action. `reboot` and `upgrade` respect the `allow_reboot` flag.

### `run_once()`

The main flow on each run:
1. Read configuration (or bootstrap if needed)
2. Collect status (`collect_status`)
3. Check in with the server (`POST /api/v1/agent/checkin`)
4. If the server reports the agent is `pending_approval` — exit without running jobs
5. Check if the agent is outdated (`agent_update.outdated`) and if `auto_agent_update` is enabled — if so, update itself and exit
6. Iterate over `jobs` in the response (max 3 per check-in)
7. Mark each job as started, run it, report the result

On exception, the error message is sent with the next check-in as `last_error`.

---

## Exactly what happens on the Ubuntu machine when a job runs

### Flow from timer tick to job result

```
systemd-timer (every 5 minutes)
  │
  └─► patchpilot-agent --once
        │
        ├─ 1. collect_status()          ← apt-get update + apt list
        ├─ 2. POST /api/v1/agent/checkin  ← sends status, receives jobs
        ├─ 3. POST /jobs/{id}/started   ← notifies that the job is starting
        ├─ 4. execute_job()             ← runs the correct Linux command
        └─ 5. POST /jobs/{id}/result    ← sends exit code + output
```

### Step 1 — collect_status(): what the APT commands do

Each check-in begins with the agent collecting system status. Three system calls are run in sequence:

**`apt-get update`**
Syncs the package lists against Ubuntu's repos (or a local mirror). Writes to `/var/lib/apt/lists/`. Requires root. Timeout: 15 minutes.

```bash
apt-get update
```

**`apt list --upgradable 2>/dev/null | tail -n +2`**
Lists all packages with available upgrades. `tail -n +2` removes the header line ("Listing..."). The output format is:

```
vim/jammy 9.1.0-1ubuntu1 amd64 [upgradable from: 9.0.0-1]
openssl/jammy-security 3.0.2-0ubuntu1.12 amd64 [upgradable from: 3.0.2-0ubuntu1.10]
```

The agent parses each line with regex and marks a package as CVE-related if the source name contains `security` (e.g. `jammy-security`).

**`/usr/lib/update-notifier/apt-check`** *(if the file exists)*
Ubuntu tool that gives more accurate counts of total and security-related updates. Present on most Ubuntu installations. Output format: `42;5` (42 total, 5 security-related).

**Check for `/var/run/reboot-required`**
APT creates this file automatically when an installed package requires a reboot to be activated (e.g. new kernel, new glibc). The agent reports `"reboot_required": true` if the file exists.

**Reads `/etc/os-release`**
Standard file on all modern Linux distributions. The agent reads the `PRETTY_NAME` line, e.g. `Ubuntu 22.04.3 LTS`.

**`platform.release()`**
Python stdlib call that runs `uname -r` internally and returns the kernel version, e.g. `5.15.0-91-generic`.

---

### Step 4 — execute_job(): Linux commands per job type

#### `check_updates`

Runs the full `collect_status()` again (updates package lists and recounts). Returns all status as JSON. Nothing is installed, nothing changes on the system.

```bash
apt-get update
apt list --upgradable 2>/dev/null
/usr/lib/update-notifier/apt-check   # if present
```

---

#### `upgrade`

```bash
apt-get update && apt-get upgrade -y
```

- `apt-get upgrade -y` upgrades all packages that have a newer version available, **without** removing existing packages or installing new ones (that requires `dist-upgrade`/`full-upgrade`).
- `-y` automatically answers yes to all questions.
- `DEBIAN_FRONTEND=noninteractive` is set in the environment — prevents interactive dialogs (e.g. whether `/etc/ssh/sshd_config` should be overwritten by a package update).
- `NEEDRESTART_MODE=a` is set in the environment — makes `needrestart` (an Ubuntu tool that asks whether services should be restarted) run automatically without prompting.
- If `allow_reboot=true` and `/var/run/reboot-required` exists after the upgrade, `systemctl reboot` is run.

Timeout: 2 hours.

---

#### `security_upgrade`

```bash
apt-get update && unattended-upgrade -d
```

- `unattended-upgrade` is Ubuntu's built-in tool for automatic security updates. It reads `/etc/apt/apt.conf.d/50unattended-upgrades` to determine which packages are approved.
- By default it only upgrades packages from `Ubuntu:jammy-security` and `UbuntuESM:jammy-infra-security`.
- `-d` (debug) writes detailed output that the agent captures and reports back.
- Does **not** upgrade non-security packages — e.g. vim gets a new version via `upgrade` but not via `security_upgrade` unless it is a CVE fix.
- If `allow_reboot=true` and a reboot is required, `systemctl reboot` is run.

Timeout: 2 hours.

---

#### `apt_clean`

```bash
apt-get autoremove -y && apt-get autoclean -y
```

- `autoremove` removes packages that were installed automatically as dependencies but are no longer needed by any installed package.
- `autoclean` removes package files (`.deb`) from APT's local cache (`/var/cache/apt/archives/`) for packages that no longer exist in the repos or have been replaced by newer versions. Does not touch the working installation.

---

#### `reboot`

```bash
systemctl reboot
```

- Only runs if `allow_reboot=true` in the job — otherwise exit code 1 is returned with the message `"Reboot refused because allow_reboot is false"`.
- `systemctl reboot` requests a reboot from the init system (systemd). It is a controlled reboot — `systemd` shuts down services in the correct order.
- The agent does not have time to report any meaningful result after the reboot has started. The server marks the job as `success` anyway if the exit code from the `systemctl reboot` call is 0 (which it is before the machine shuts down).

---

#### `self_update`

See [self_update_agent()](#self_update_agentupdate_url-expected_sha256) in the Agent functions section for a full walkthrough. In brief:

```
1. curl-equivalent against /agent/patchpilot-agent.py   (urllib, no external deps)
2. SHA256 verification against the server's manifest
3. Write temp file in /usr/local/bin/   (same filesystem as the target)
4. chmod 755 temp file
5. Backup: /usr/local/bin/patchpilot-agent.bak-{version}
6. rename(temp file → /usr/local/bin/patchpilot-agent)   ← atomic
```

Linux system calls that are actually made:
- `open()` + `write()` — writes the temp file
- `chmod()` — sets execute permissions
- `rename()` — atomic file swap (a single syscall, never partial)

---

### Environment variables set for all APT commands

| Variable | Value | Why |
|---|---|---|
| `DEBIAN_FRONTEND` | `noninteractive` | Prevents APT from opening interactive dialogs (debconf) |
| `NEEDRESTART_MODE` | `a` | Makes `needrestart` automatically restart services without prompting |

Without `DEBIAN_FRONTEND=noninteractive`, an upgrade of e.g. `openssh-server` can hang waiting for an answer about whether the config file should be kept or overwritten — forever, until timeout.

---

### Security boundary: what the agent CANNOT do

The agent always validates `action` against:

```python
ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot",
                   "security_upgrade", "self_update", "upgrade"}
```

If the server (or anyone else) sends a job with `action = "rm -rf /"` or any other command not in the list, the agent immediately returns:

```
exit_code=1, output="Refused invalid action: rm -rf /"
```

The command is never executed. There is no eval, no exec of server responses, no dynamic commands.

---

## Server — authentication and security

Defined in `backend/app/security.py` and `backend/app/main.py`.

### Agent token

```python
def new_token(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(32)}"
```

Generates a token with 32 bytes of random entropy (256 bit), URL-safe base64-encoded. Results in strings like `pp_agent_xK3mN...` (~46 characters). `secrets.token_urlsafe` uses the OS's CSPRNG (`os.urandom`).

```python
def hash_token(token: str) -> str:
    return pwd_context.hash(token)   # bcrypt, cost factor 12

def verify_token(token: str, token_hash: str) -> bool:
    return pwd_context.verify(token, token_hash)
```

bcrypt stores the salt embedded in the hash string. `verify` is constant-time to prevent timing attacks.

### CSRF protection

```python
def make_csrf_token() -> str:
    secret = os.getenv("APP_SECRET")
    hour = str(int(time.time()) // 3600)   # current hour as string
    return hmac.new(secret.encode(), hour.encode(), hashlib.sha256).hexdigest()[:32]
```

The token is deterministic within the same hour. This means the page can be reloaded without the CSRF token being invalidated.

```python
def verify_csrf_token(token: str) -> bool:
    for offset in (0, 1):   # accepts current and previous hour
        expected = hmac.new(secret, (current_hour - offset), sha256)[:32]
        if hmac.compare_digest(token, expected):
            return True
    return False
```

`hmac.compare_digest` is constant-time — prevents timing-based guessing attacks. Tokens are valid for up to 2 hours, which covers the edge case of a page being loaded 59 minutes into an hour and the form being submitted 1 minute later.

### Admin HTTP Basic Auth

```python
@app.middleware("http")
async def admin_auth_middleware(request: Request, call_next):
    admin_password = os.getenv("ADMIN_PASSWORD", "").strip()
    if admin_password and request.url.path.startswith("/admin"):
        ...
        if hmac.compare_digest(pw, admin_password):
            return await call_next(request)
        return Response("Unauthorized", status_code=401,
            headers={"WWW-Authenticate": 'Basic realm="PatchPilot Admin"'})
```

Only activated if `ADMIN_PASSWORD` is set. The password is compared with `hmac.compare_digest` — constant-time. Middleware runs **before** routers, meaning authentication can never be bypassed by routing logic.

### Host-based routing

```python
@app.middleware("http")
async def host_path_guard(request: Request, call_next):
    host = request.headers.get("host", "").split(":")[0].lower()
    path = request.url.path

    if host == AGENT_PUBLIC_HOSTNAME:
        if not (path.startswith("/api/") or path in ("/healthz", "/install.sh", ...)):
            return Response(status_code=404)

    if host in ADMIN_INTERNAL_HOSTNAMES:
        if path.startswith("/api/v1/agent/"):
            return Response(status_code=404)
```

The agent's public hostname cannot reach `/admin`. The admin's internal hostname cannot reach the agent API. This means that even if the admin interface is accidentally exposed publicly, no one can use it as an agent proxy.

### Rate limiting for enrollment

```python
_enroll_timestamps: dict[str, list[float]] = defaultdict(list)

def _check_enroll_rate(ip: str) -> bool:
    now = time.time()
    valid = [t for t in _enroll_timestamps[ip] if now - t < 3600.0]
    _enroll_timestamps[ip] = valid
    if len(valid) >= 10:
        return False
    _enroll_timestamps[ip].append(now)
    return True
```

In-memory sliding window. Automatically clears old timestamps on each check. Resets on server restart. Max 10 enrollments per IP per hour.

### Agent authentication

```python
def get_agent(db, x_agent_id, authorization):
    if not x_agent_id or not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401)
    token = authorization[7:]
    machine = db.query(Machine).filter(Machine.machine_id == x_agent_id).first()
    if not machine or not machine.active or not verify_token(token, machine.token_hash):
        raise HTTPException(status_code=401)
    return machine
```

Every agent request requires two headers: `X-Agent-ID` (machine ID) and `Authorization: Bearer <token>`. The machine is looked up by `machine_id`, and then the token is verified against the stored bcrypt hash. An agent cannot access another agent's jobs — `Job.machine_id` is always checked.

---

## Server — agent API

### `POST /api/v1/agent/enroll`

1. Validates that `machine_id` and `hostname` are present in the payload (400 if missing)
2. Checks rate limit for the client's IP (429 if too many attempts)
3. Checks if the machine is already registered:
   - If the machine is inactive/disabled — returns 403
   - If the machine exists — returns `"message": "machine already enrolled"` without a new token
4. Generates a new token, creates the machine record in the database
5. The `PATCHPILOT_AUTO_APPROVE_AGENTS` environment variable controls whether the machine is approved immediately or placed in `pending_approval`
6. Writes to the audit log and sends a Discord notification
7. Returns `agent_token` in plaintext — **the only time the token is visible**

### `POST /api/v1/agent/checkin`

1. Authenticates the agent (see `get_agent` above)
2. Updates the machine's status fields in the database
3. Handles the package list: deletes all old `PackageUpdate` rows for the machine, writes in new ones (max 500 packages)
4. Fetches latest agent info (version and SHA256 from the served file)
5. If the machine is not approved — returns `pending_approval` with empty `jobs`
6. Fetches up to 3 `pending` jobs, sorted by `created_at`
7. Returns the job list, policy flags (`auto_patch`, `auto_reboot`, `auto_agent_update`), and agent update information

### `POST /api/v1/agent/jobs/{id}/started`

Verifies that the job belongs to the authenticated agent (`Job.machine_id == machine.id`). Sets `status = "running"` and `started_at = now`. Returns 404 if the job does not exist or belongs to a different agent.

### `POST /api/v1/agent/jobs/{id}/result`

Receives `exit_code` and `output` (truncated to 30,000 characters). Sets status to `success` (exit 0) or `failed` (exit != 0). Updates `last_success_at` or `last_error`. Writes to the audit log. Sends a Discord notification on failure or on successful `upgrade`/`security_upgrade`/`reboot`.

### `GET /api/v1/agent/latest`

```python
def latest_agent_info():
    path = Path("app/static/patchpilot-agent.py")
    data = path.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    version = re.search(r'AGENT_VERSION\s*=\s*["\']([^"\']+)', data.decode()).group(1)
    return {"version": version, "sha256": sha256, "url": f"{PUBLIC_AGENT_URL}/agent/patchpilot-agent.py"}
```

Reads the agent file from disk on every call, computes SHA256, and extracts the version string with regex. No caching — always reflects the current file.

---

## Server — admin API

All admin endpoints require a valid CSRF token (automatically injected by JS in the admin interface). Without a token, 403 is returned.

### CSRF dependency

```python
def require_csrf(csrf_token: str = Form(default="")) -> None:
    if not verify_csrf_token(csrf_token):
        raise HTTPException(status_code=403, detail="Invalid CSRF token")
```

Declared as `_: None = Depends(require_csrf)` on every POST endpoint. FastAPI runs the dependency **before** the handler logic — if CSRF validation fails, the code never reaches the database operations.

### Job creation

Validates `action` against `ALLOWED_ACTIONS` (400 if invalid). Creates a `Job` object with `status="pending"`. Writes audit log and Discord notification. All admin POSTs return `RedirectResponse("/admin", status_code=303)` — after a form submit the browser is redirected with GET, which prevents the form from being resubmitted on page refresh (the PRG pattern).

### Job approval

Sets `job.status = "pending"` (from `approval_required`). The job is picked up by the agent at the next check-in.

### Token rotation

Generates a new token, hashes it, and saves it in the database. Returns the plaintext token directly in the response (as plain text). The administrator copies it and manually updates `/etc/patchpilot/agent.json` on the agent machine.

### Machine deletion

Deletes all related rows in order: `jobs` → `package_updates` → `machine_groups` → `machines`. Without this order, foreign key constraints would block the deletion.

### Schedule linking

Schedules are saved with target type (`machine` or `group`) and target ID. On creation, `action`, `target_type`, and `day_of_week` are validated against hardcoded sets. `time_of_day` is validated with `re.fullmatch(r"\d{2}:\d{2}", ...)`.

---

## Scheduler

```python
scheduler = BackgroundScheduler()

@app.on_event("startup")
def startup():
    scheduler.add_job(run_schedules, "interval", seconds=60, id="patchpilot_scheduler")
    scheduler.start()
```

APScheduler runs as a background thread in the same process as FastAPI. `run_schedules()` is called once per minute.

### `run_schedules()`

```python
def run_schedules():
    with SessionLocal() as db:
        now = datetime.now(ZoneInfo(schedule.timezone))
        current_hour_min = now.strftime("%H:%M")
        current_dow = DAYS[now.weekday()]
        run_key = f"{s.id}:{now.date()}"

        if not s.enabled: continue
        if s.last_run_key == run_key: continue  # already run today
        if s.day_of_week != "all" and DAYS[s.day_of_week] != current_dow: continue
        if s.time_of_day != current_hour_min: continue  # exact match

        # Create job for the machine or all machines in the group
        status = "approval_required" if s.require_approval else "pending"
        ...
        s.last_run_key = run_key
        s.last_run_at = datetime.utcnow()
```

Timezone handling is done with Python's `zoneinfo` (built into Python 3.9+). Scheduler times are compared in the schedule's local timezone — if a schedule is configured for `03:00 Europe/Stockholm`, it triggers at 03:00 local time regardless of the server's timezone.

`last_run_key` in the format `{schedule_id}:{date}` is a simple deduplication guarantee: if the scheduler happens to run twice in the same minute (e.g. on restart), only one set of jobs is created.

---

## Notifications

```python
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "")

def notify_discord(message: str):
    if not DISCORD_WEBHOOK_URL:
        return
    try:
        urllib_request.urlopen(
            urllib_request.Request(
                DISCORD_WEBHOOK_URL,
                data=json.dumps({"content": message}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            ),
            timeout=5,
        )
    except Exception:
        pass   # notification failures must never affect the API response
```

Discord notifications are sent synchronously but with a short timeout (5 s) and all exceptions are silently ignored. This means a Discord outage never blocks enrollment, check-in, or job results.

Notifications are sent on:
- New agent enrolled (pending or auto-approved)
- Agent approved/rejected by admin
- Job queued by admin
- Job failed
- Successful `upgrade`, `security_upgrade`, or `reboot`

---

## Install scripts

The server generates install scripts dynamically in memory — they are never written to disk. This ensures the server URL is always correct and the SHA256 sum is always fresh.

### `GET /install.sh` — direct installation

1. Downloads the agent file to `/usr/local/bin/patchpilot-agent`
2. Fetches `GET /api/v1/agent/latest` to get the expected SHA256
3. Computes `sha256sum` locally with the `sha256sum` command
4. Compares — aborts and deletes the agent file if checksums don't match
5. Runs `patchpilot-agent --enroll --server $SERVER_URL`
6. Installs the systemd service and systemd timer
7. Activates the timer immediately

### `GET /template-install.sh` — VM template installation

Same as above but:
- Does **not** run enrollment at installation time
- Writes `/etc/patchpilot/bootstrap.json` with `{"server_url": "...", "template_mode": true}`
- Deletes `/etc/patchpilot/agent.json` and `/etc/patchpilot/machine-id` (ensures cloned VMs get unique identities)
- Does **not** activate the timer — it is activated by whoever deploys the VM template

When a VM is cloned from the template and started, the systemd timer runs `patchpilot-agent --once` which calls `bootstrap_if_needed()`. It finds `bootstrap.json`, runs enrollment, and creates a unique machine ID based on the cloned VM's hostname.

---

## Test suite

Definitions are in `backend/tests/`.

### Infrastructure (`conftest.py`)

Tests use SQLite in-memory (via file `test_patchpilot.db`) instead of PostgreSQL. FastAPI's dependency injection mechanism is used to swap out `get_db` for a function that delivers a session against the test database:

```python
app.dependency_overrides[get_db] = _override_db
```

The `_clean_state` fixture deletes all table rows after each test via SQLAlchemy's `table.delete()`. `_create_tables` is session-scoped and creates the tables once per test session.

SQLite guard in `migrate_db()`:
```python
def migrate_db():
    if "sqlite" in str(engine.url):
        return  # SQLite uses create_all; ALTER TABLE IF NOT EXISTS is PostgreSQL-only
```

### `test_api.py` — 30 tests

Tests all HTTP endpoints with `fastapi.testclient.TestClient`. Covers:
- Enrollment: new registration, double enrollment, missing fields, rate limiting
- Check-in: authentication, correct/wrong token, package list, truncation of large list
- Jobs: creation, started/result reporting, that the wrong agent cannot reach the right agent's jobs
- CSRF: all admin POST routes return 403 without token, 403 with wrong token, 303 with correct token
- Admin authentication: 401 without password, 200 with correct, 401 with wrong
- Host routing: agent hostname blocks `/admin`, admin hostname blocks `/api/v1/agent/`
- Admin endpoints: creation of groups, schedules (including invalid time format), machine approval

### `test_security.py` — 8 tests

Tests `security.py` in isolation:
- Token format and uniqueness
- Bcrypt hash-verify roundtrip
- CSRF token is deterministic within the hour
- Previous hour's token is accepted (max 2 hours)
- Token from 2 hours ago is rejected
- Wrong and empty token are rejected

### `test_agent.py` — 16 tests

Tests the agent's pure functions without subprocess and without network calls (everything mocked):
- `parse_apt_updates()`: empty output, normal package, security package, multiple packages, APT error
- `self_update_agent()`: missing URL, invalid file content, SHA256 mismatch, temp file in correct directory
- `get_machine_id()`: creates and persists new ID, reads existing ID
- `enroll()`: re-enrollment exits with exit 0, missing token exits with exit 1
