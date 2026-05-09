#!/usr/bin/env bash
set -euo pipefail

# PatchPilot template approval patch
# Adds:
#   - pending approval for newly enrolled agents
#   - approve/reject buttons in admin
#   - template installer endpoint /template-install.sh
#   - template-aware agent v0.5.0
#
# Run:
#   cd patchpilot
#   bash patchpilot-template-approval.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/main.py" ]]; then
  echo "ERROR: Run from inside the patchpilot project directory."
  exit 1
fi

if [[ ! -f "backend/app/models.py" ]]; then
  echo "ERROR: Missing backend/app/models.py"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="_backup_template_approval_${TS}"

echo "[+] Backup: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
cp -a backend "${BACKUP_DIR}/backend"
cp -a agent "${BACKUP_DIR}/agent" 2>/dev/null || true

echo "[+] Patching models.py"
python3 - <<'PY'
from pathlib import Path

p = Path("backend/app/models.py")
txt = p.read_text()

if "approved:" not in txt:
    marker = "    active: Mapped[bool] = mapped_column(Boolean, default=True)\n"
    insert = (
        "    approved: Mapped[bool] = mapped_column(Boolean, default=True)\n"
        "    approval_status: Mapped[str] = mapped_column(String(64), default=\"approved\")\n"
        "    approved_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)\n"
        "    rejected_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)\n"
        "    first_seen: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)\n"
    )
    if marker not in txt:
        raise SystemExit("Could not find Machine.active column")
    txt = txt.replace(marker, marker + insert, 1)

p.write_text(txt)
PY

echo "[+] Patching main.py"
python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/main.py")
txt = p.read_text()

if "from sqlalchemy import text" not in txt:
    txt = txt.replace("from sqlalchemy.orm import Session", "from sqlalchemy import text\nfrom sqlalchemy.orm import Session")

# Add model migrations to existing migrate_db.
if "ALTER TABLE machines ADD COLUMN IF NOT EXISTS approved BOOLEAN" not in txt:
    if "def migrate_db():" in txt:
        m = re.search(r"(def migrate_db\(\):\n\s+statements\s*=\s*\[)", txt)
        if not m:
            raise SystemExit("Found migrate_db but could not patch statements list")
        additions = (
            "\n        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approved BOOLEAN DEFAULT TRUE\","
            "\n        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approval_status VARCHAR(64) DEFAULT 'approved'\","
            "\n        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approved_at TIMESTAMP\","
            "\n        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMP\","
            "\n        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS first_seen TIMESTAMP\","
        )
        txt = txt[:m.end()] + additions + txt[m.end():]
    else:
        marker = "Base.metadata.create_all(bind=engine)"
        if marker not in txt:
            raise SystemExit("Could not find Base.metadata.create_all")
        migrate_func = (
            "\n\ndef migrate_db():\n"
            "    statements = [\n"
            "        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approved BOOLEAN DEFAULT TRUE\",\n"
            "        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approval_status VARCHAR(64) DEFAULT 'approved'\",\n"
            "        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS approved_at TIMESTAMP\",\n"
            "        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS rejected_at TIMESTAMP\",\n"
            "        \"ALTER TABLE machines ADD COLUMN IF NOT EXISTS first_seen TIMESTAMP\",\n"
            "    ]\n"
            "    with engine.begin() as conn:\n"
            "        for stmt in statements:\n"
            "            conn.execute(text(stmt))\n"
            "        conn.execute(text(\"UPDATE machines SET approved = TRUE WHERE approved IS NULL\"))\n"
            "        conn.execute(text(\"UPDATE machines SET approval_status = 'approved' WHERE approval_status IS NULL\"))\n"
            "        conn.execute(text(\"UPDATE machines SET first_seen = created_at WHERE first_seen IS NULL\"))\n"
            "\n"
            "migrate_db()\n"
        )
        txt = txt.replace(marker, marker + migrate_func, 1)

if "UPDATE machines SET approved = TRUE WHERE approved IS NULL" not in txt:
    old = "        for stmt in statements:\n            conn.execute(text(stmt))\n"
    new = (
        "        for stmt in statements:\n"
        "            conn.execute(text(stmt))\n"
        "        conn.execute(text(\"UPDATE machines SET approved = TRUE WHERE approved IS NULL\"))\n"
        "        conn.execute(text(\"UPDATE machines SET approval_status = 'approved' WHERE approval_status IS NULL\"))\n"
        "        conn.execute(text(\"UPDATE machines SET first_seen = created_at WHERE first_seen IS NULL\"))\n"
    )
    if old in txt:
        txt = txt.replace(old, new, 1)

if "def migrate_db():" in txt and "\nmigrate_db()\n" not in txt:
    marker = "Base.metadata.create_all(bind=engine)"
    txt = txt.replace(marker, marker + "\nmigrate_db()", 1)

# Replace enroll route.
start = txt.find('@app.post("/api/v1/agent/enroll")')
if start == -1:
    raise SystemExit("Could not find enroll route")
m = re.search(r"\n@app\.", txt[start+1:])
if not m:
    raise SystemExit("Could not find end of enroll route")
end = start + 1 + m.start()

new_enroll = '''@app.post("/api/v1/agent/enroll")
def enroll_agent(payload: dict, request: Request, db: Session = Depends(get_db)):
    machine_id = payload.get("machine_id")
    hostname = payload.get("hostname")
    agent_version = payload.get("agent_version")
    os_version = payload.get("os_version")
    kernel_version = payload.get("kernel_version")

    if not machine_id or not hostname:
        raise HTTPException(status_code=400, detail="machine_id and hostname required")

    existing = db.query(Machine).filter(Machine.machine_id == machine_id).first()
    if existing:
        if not existing.active:
            raise HTTPException(status_code=403, detail="agent is disabled or rejected")
        return {
            "machine_id": existing.machine_id,
            "status": existing.approval_status or ("approved" if existing.approved else "pending_approval"),
            "approved": bool(existing.approved),
            "message": "machine already enrolled"
        }

    token = new_token("pp_agent")
    auto_approve = os.getenv("PATCHPILOT_AUTO_APPROVE_AGENTS", "false").lower() in {"1", "true", "yes", "on"}

    machine = Machine(
        machine_id=machine_id,
        hostname=hostname,
        token_hash=hash_token(token),
        ip_address=request.client.host if request.client else None,
        first_seen=datetime.utcnow(),
        last_seen=datetime.utcnow(),
        agent_version=agent_version,
        os_version=os_version,
        kernel_version=kernel_version,
        active=True,
        approved=auto_approve,
        approval_status="approved" if auto_approve else "pending_approval",
        approved_at=datetime.utcnow() if auto_approve else None,
    )

    db.add(machine)
    audit(
        db,
        "agent_enrolled_pending" if not auto_approve else "agent_enrolled_auto_approved",
        actor="agent",
        target_type="machine",
        target_id=machine_id,
        details=f"hostname={hostname}",
        request=request,
    )
    db.commit()

    if not auto_approve:
        notify_discord(f"PatchPilot: new agent pending approval: {hostname} ({machine_id})")
    else:
        notify_discord(f"PatchPilot: new agent auto-approved: {hostname} ({machine_id})")

    return {
        "machine_id": machine_id,
        "agent_token": token,
        "status": machine.approval_status,
        "approved": bool(machine.approved),
        "message": "Agent registered. Waiting for admin approval." if not machine.approved else "Agent registered and approved."
    }

'''
txt = txt[:start] + new_enroll + txt[end+1:]

# Replace checkin route.
start = txt.find('@app.post("/api/v1/agent/checkin")')
if start == -1:
    raise SystemExit("Could not find checkin route")
m = re.search(r"\n@app\.", txt[start+1:])
if not m:
    raise SystemExit("Could not find end of checkin route")
end = start + 1 + m.start()

new_checkin = '''@app.post("/api/v1/agent/checkin")
def checkin(
    payload: dict,
    request: Request,
    x_agent_id: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
    db: Session = Depends(get_db),
):
    machine = get_agent(db, x_agent_id, authorization)

    machine.hostname = payload.get("hostname", machine.hostname)
    machine.os_version = payload.get("os_version")
    machine.kernel_version = payload.get("kernel_version")
    machine.agent_version = payload.get("agent_version")
    machine.updates_available = int(payload.get("updates_available", 0))
    machine.security_updates_available = int(payload.get("security_updates_available", 0))
    machine.reboot_required = bool(payload.get("reboot_required", False))
    machine.last_error = payload.get("last_error")
    machine.ip_address = request.client.host if request.client else None
    machine.last_seen = datetime.utcnow()
    if not machine.first_seen:
        machine.first_seen = datetime.utcnow()

    packages = payload.get("packages", [])
    if isinstance(packages, list):
        db.query(PackageUpdate).filter(PackageUpdate.machine_id == machine.id).delete()
        for pkg in packages[:500]:
            if not isinstance(pkg, dict) or not pkg.get("package"):
                continue
            db.add(PackageUpdate(
                machine_id=machine.id,
                package=str(pkg.get("package"))[:255],
                current_version=str(pkg.get("current_version") or "")[:255] or None,
                candidate_version=str(pkg.get("candidate_version") or "")[:255] or None,
                security=bool(pkg.get("security", False)),
                raw=str(pkg.get("raw") or "")[:2000] or None,
            ))

    db.commit()

    latest = latest_agent_info() if "latest_agent_info" in globals() else {"version": "unknown", "sha256": "", "url": ""}
    auto_agent_update = os.getenv("PATCHPILOT_AUTO_AGENT_UPDATE", "false").lower() in {"1", "true", "yes", "on"}

    if not machine.approved:
        return {
            "status": "pending_approval",
            "approved": False,
            "policy": {
                "auto_patch": False,
                "auto_reboot": False,
                "auto_agent_update": False,
            },
            "agent_update": {
                "current_version": machine.agent_version,
                "latest_version": latest["version"],
                "sha256": latest["sha256"],
                "url": latest["url"],
                "outdated": False,
            },
            "jobs": [],
        }

    jobs = (
        db.query(Job)
        .filter(Job.machine_id == machine.id, Job.status == "pending")
        .order_by(Job.created_at.asc())
        .limit(3)
        .all()
    )

    return {
        "status": "ok",
        "approved": True,
        "policy": {
            "auto_patch": machine.auto_patch,
            "auto_reboot": machine.auto_reboot,
            "auto_agent_update": auto_agent_update,
        },
        "agent_update": {
            "current_version": machine.agent_version,
            "latest_version": latest["version"],
            "sha256": latest["sha256"],
            "url": latest["url"],
            "outdated": agent_is_outdated(machine.agent_version, latest["version"]) if "agent_is_outdated" in globals() else False,
        },
        "jobs": [{"id": job.id, "action": job.action, "allow_reboot": job.allow_reboot} for job in jobs],
    }

'''
txt = txt[:start] + new_checkin + txt[end+1:]

if "/admin/machines/{machine_pk}/approve" not in txt:
    txt += '''

# PATCHPILOT_TEMPLATE_APPROVAL_ROUTES
@app.post("/admin/machines/{machine_pk}/approve")
def approve_machine(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")

    machine.approved = True
    machine.approval_status = "approved"
    machine.approved_at = datetime.utcnow()
    machine.rejected_at = None
    machine.active = True

    audit(db, "machine_approved", target_type="machine", target_id=str(machine.id), details=machine.hostname, request=request)
    db.commit()
    notify_discord(f"PatchPilot: agent approved: {machine.hostname}")
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/machines/{machine_pk}/reject")
def reject_machine(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")

    machine.approved = False
    machine.approval_status = "rejected"
    machine.rejected_at = datetime.utcnow()
    machine.active = False

    db.query(Job).filter(Job.machine_id == machine.id, Job.status.in_(["pending", "approval_required", "running"])).delete()
    audit(db, "machine_rejected", target_type="machine", target_id=str(machine.id), details=machine.hostname, request=request)
    db.commit()
    notify_discord(f"PatchPilot: agent rejected: {machine.hostname}")
    return RedirectResponse("/admin", status_code=303)
'''

if '@app.get("/template-install.sh"' not in txt:
    txt += '''

@app.get("/template-install.sh", response_class=PlainTextResponse)
def template_install_agent_script(request: Request):
    detected_server_url = os.getenv("PUBLIC_AGENT_URL", str(request.base_url).rstrip("/")).rstrip("/")
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
  echo "ERROR: Run as root"
  exit 1
fi

echo "[+] PatchPilot template agent installer"
echo "[+] Server URL: $SERVER_URL"
echo "[+] This installs the agent for VM templates without enrolling now."

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y python3 ca-certificates unattended-upgrades curl

install -d -m 700 /etc/patchpilot
curl -fsSL "$AGENT_URL" -o /usr/local/bin/patchpilot-agent
chmod 755 /usr/local/bin/patchpilot-agent

cat > /etc/patchpilot/bootstrap.json <<BOOTSTRAP
{{
  "server_url": "$SERVER_URL",
  "template_mode": true
}}
BOOTSTRAP
chmod 600 /etc/patchpilot/bootstrap.json

rm -f /etc/patchpilot/agent.json
rm -f /etc/patchpilot/machine-id

cat > /etc/systemd/system/patchpilot-agent.service <<'UNIT'
[Unit]
Description=PatchPilot Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PYTHONUNBUFFERED=1
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
systemctl enable patchpilot-agent.timer

echo
echo "[+] Template agent installed."
echo "[+] Do NOT start/enroll before converting to template unless you want this builder VM enrolled."
echo "[+] On cloned VM first boot, timer enrolls it as pending approval."
"""
    return PlainTextResponse(
        script,
        media_type="text/x-shellscript; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )
'''

p.write_text(txt)
PY

echo "[+] Writing template-aware agent v0.5.0"

cat > agent/patchpilot-agent.py <<'PYEOF'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import re
import socket
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from urllib import request, error

AGENT_VERSION = "0.5.0"
CONFIG_PATH = Path("/etc/patchpilot/agent.json")
BOOTSTRAP_PATH = Path("/etc/patchpilot/bootstrap.json")
ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}

def run(cmd, timeout=1800):
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    env["NEEDRESTART_MODE"] = "a"
    p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout, env=env)
    return p.returncode, (p.stdout + "\n" + p.stderr).strip()

def save_config(cfg):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    os.chmod(CONFIG_PATH, 0o600)

def load_json(path):
    return json.loads(Path(path).read_text())

def http_json(method, url, data=None, headers=None):
    body = None
    if data is not None:
        body = json.dumps(data).encode()
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": f"PatchPilot-Agent/{AGENT_VERSION}",
    }
    if headers:
        h.update(headers)

    req = request.Request(url, data=body, method=method, headers=h)
    try:
        with request.urlopen(req, timeout=90) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.read().decode()}", file=sys.stderr)
        raise

def get_machine_id():
    mid_path = Path("/etc/patchpilot/machine-id")
    if mid_path.exists():
        return mid_path.read_text().strip()

    machine_id = f"{socket.gethostname()}-{uuid.uuid4().hex[:12]}"
    mid_path.parent.mkdir(parents=True, exist_ok=True)
    mid_path.write_text(machine_id)
    os.chmod(mid_path, 0o600)
    return machine_id

def parse_apt_updates():
    rc, out = run("apt list --upgradable 2>/dev/null | tail -n +2", timeout=180)
    packages = []
    if rc != 0:
        return packages

    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue

        pkg_name = line.split("/", 1)[0]
        candidate = None
        current = None
        security = "security" in line.lower()

        parts = line.split()
        if len(parts) >= 2:
            candidate = parts[1]

        m = re.search(r"\[upgradable from:\s*([^\]]+)\]", line)
        if m:
            current = m.group(1)

        packages.append({
            "package": pkg_name,
            "current_version": current,
            "candidate_version": candidate,
            "security": security,
            "raw": line,
        })

    return packages

def apt_check_counts(packages):
    updates = len(packages)
    security = len([p for p in packages if p.get("security")])

    checker = Path("/usr/lib/update-notifier/apt-check")
    if checker.exists():
        rc, out = run("/usr/lib/update-notifier/apt-check 2>/dev/null || true", timeout=120)
        m = re.search(r"(\d+)\s*;\s*(\d+)", out)
        if m:
            updates = int(m.group(1))
            security = int(m.group(2))

    return updates, security

def get_os_version():
    if Path("/etc/os-release").exists():
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip('"')
    return ""

def collect_status(last_error=None):
    run("apt-get update", timeout=900)
    packages = parse_apt_updates()
    updates, security = apt_check_counts(packages)

    return {
        "hostname": socket.gethostname(),
        "os_version": get_os_version(),
        "kernel_version": platform.release(),
        "agent_version": AGENT_VERSION,
        "updates_available": updates,
        "security_updates_available": security,
        "reboot_required": Path("/var/run/reboot-required").exists(),
        "packages": packages,
        "last_error": last_error,
    }

def auth_headers(cfg):
    return {
        "X-Agent-ID": cfg["machine_id"],
        "Authorization": f"Bearer {cfg['agent_token']}",
    }

def enroll(server_url):
    machine_id = get_machine_id()
    payload = {
        "machine_id": machine_id,
        "hostname": socket.gethostname(),
        "agent_version": AGENT_VERSION,
        "os_version": get_os_version(),
        "kernel_version": platform.release(),
    }
    resp = http_json("POST", f"{server_url.rstrip('/')}/api/v1/agent/enroll", payload)

    if "agent_token" not in resp:
        print(f"Enroll response did not contain agent_token: {resp}", file=sys.stderr)
        sys.exit(1)

    cfg = {
        "server_url": server_url.rstrip("/"),
        "machine_id": machine_id,
        "agent_token": resp["agent_token"],
    }
    save_config(cfg)
    print(f"Enrolled as {machine_id} with status={resp.get('status')} approved={resp.get('approved')}")

def bootstrap_if_needed():
    if CONFIG_PATH.exists():
        return load_json(CONFIG_PATH)

    if not BOOTSTRAP_PATH.exists():
        print(f"Missing config: {CONFIG_PATH} and missing bootstrap: {BOOTSTRAP_PATH}", file=sys.stderr)
        sys.exit(1)

    bootstrap = load_json(BOOTSTRAP_PATH)
    server_url = bootstrap.get("server_url")
    if not server_url:
        print(f"Missing server_url in {BOOTSTRAP_PATH}", file=sys.stderr)
        sys.exit(1)

    print(f"No agent config found. Bootstrapping enrollment to {server_url}")
    enroll(server_url)
    return load_json(CONFIG_PATH)

def self_update_agent(update_url, expected_sha256=None):
    if not update_url:
        return 1, "Missing agent update URL"

    current_path = Path("/usr/local/bin/patchpilot-agent")
    if not current_path.exists():
        return 1, f"Current agent path not found: {current_path}"

    try:
        req = request.Request(
            update_url,
            method="GET",
            headers={
                "User-Agent": f"PatchPilot-Agent/{AGENT_VERSION}",
                "Accept": "text/x-python,text/plain,*/*",
            },
        )
        with request.urlopen(req, timeout=120) as resp:
            data = resp.read()

        if not data.startswith(b"#!/usr/bin/env python3"):
            return 1, "Downloaded file does not look like PatchPilot agent"

        got_sha256 = hashlib.sha256(data).hexdigest()
        if expected_sha256 and expected_sha256 != got_sha256:
            return 1, f"SHA256 mismatch. expected={expected_sha256} got={got_sha256}"

        with tempfile.NamedTemporaryFile("wb", delete=False, dir="/tmp", prefix="patchpilot-agent-", suffix=".new") as tmp:
            tmp.write(data)
            tmp_path = Path(tmp.name)

        os.chmod(tmp_path, 0o755)

        backup_path = Path(f"/usr/local/bin/patchpilot-agent.bak-{AGENT_VERSION}")
        try:
            backup_path.write_bytes(current_path.read_bytes())
            os.chmod(backup_path, 0o755)
        except Exception:
            pass

        tmp_path.replace(current_path)
        os.chmod(current_path, 0o755)

        return 0, f"Agent updated successfully. old_version={AGENT_VERSION} sha256={got_sha256}"

    except Exception as e:
        return 1, f"Agent self-update failed: {e}"

def execute_job(job):
    action = job.get("action")
    allow_reboot = bool(job.get("allow_reboot", False))

    if action not in ALLOWED_ACTIONS:
        return 1, f"Refused invalid action: {action}"

    if action == "check_updates":
        status = collect_status()
        return 0, json.dumps(status, indent=2)

    if action == "upgrade":
        rc, out = run("apt-get update && apt-get upgrade -y", timeout=7200)
        if rc == 0 and allow_reboot and Path("/var/run/reboot-required").exists():
            run("systemctl reboot", timeout=10)
        return rc, out

    if action == "security_upgrade":
        rc, out = run("apt-get update && unattended-upgrade -d", timeout=7200)
        if rc == 0 and allow_reboot and Path("/var/run/reboot-required").exists():
            run("systemctl reboot", timeout=10)
        return rc, out

    if action == "reboot":
        if not allow_reboot:
            return 1, "Reboot refused because allow_reboot is false"
        run("systemctl reboot", timeout=10)
        return 0, "Reboot requested"

    if action == "apt_clean":
        return run("apt-get autoremove -y && apt-get autoclean -y", timeout=1800)

    if action == "self_update":
        return self_update_agent(job.get("update_url"), job.get("sha256"))

    return 1, "Unhandled action"

def run_once():
    cfg = bootstrap_if_needed()
    server = cfg["server_url"].rstrip("/")

    try:
        status = collect_status()
        resp = http_json("POST", f"{server}/api/v1/agent/checkin", status, auth_headers(cfg))

        if resp.get("status") == "pending_approval":
            print("Agent is pending approval. No jobs will be executed.")
            return

        update_info = resp.get("agent_update") or {}
        policy = resp.get("policy") or {}

        if update_info.get("outdated") and policy.get("auto_agent_update"):
            exit_code, output = self_update_agent(update_info.get("url"), update_info.get("sha256"))
            if exit_code != 0:
                raise RuntimeError(output)
            print(output)
            return

        for job in resp.get("jobs", []):
            job_id = job["id"]

            if job.get("action") == "self_update":
                job["update_url"] = update_info.get("url")
                job["sha256"] = update_info.get("sha256")

            http_json("POST", f"{server}/api/v1/agent/jobs/{job_id}/started", {}, auth_headers(cfg))
            exit_code, output = execute_job(job)
            http_json(
                "POST",
                f"{server}/api/v1/agent/jobs/{job_id}/result",
                {"exit_code": exit_code, "output": output},
                auth_headers(cfg),
            )

    except Exception as e:
        last_error = str(e)
        try:
            status = collect_status(last_error=last_error)
            http_json("POST", f"{server}/api/v1/agent/checkin", status, auth_headers(cfg))
        except Exception:
            pass
        raise

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--enroll", action="store_true")
    parser.add_argument("--server")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    if args.enroll:
        if not args.server:
            print("--server is required with --enroll", file=sys.stderr)
            sys.exit(1)
        enroll(args.server)
    else:
        run_once()
PYEOF

chmod +x agent/patchpilot-agent.py
mkdir -p backend/app/static
cp agent/patchpilot-agent.py backend/app/static/patchpilot-agent.py
chmod 644 backend/app/static/patchpilot-agent.py

echo "[+] Patching admin UI approval controls"
python3 - <<'PY'
from pathlib import Path

p = Path("backend/app/templates/admin.html")
if not p.exists():
    raise SystemExit("admin.html missing")

txt = p.read_text()

if "pending approval" not in txt.lower():
    txt = txt.replace(
        "{% if m.reboot_required %}<br><br><span class=\"badge warn\">reboot</span>{% endif %}",
        "{% if not m.approved %}<br><br><span class=\"badge purple\">pending approval</span>{% endif %}\n                  {% if m.reboot_required %}<br><br><span class=\"badge warn\">reboot</span>{% endif %}"
    )

if "/admin/machines/{{ m.id }}/approve" not in txt:
    marker = "{% if m.active %}"
    approval_block = '''{% if not m.approved and m.approval_status != 'rejected' %}
                      <form class="inline" method="post" action="/admin/machines/{{ m.id }}/approve">
                        <button class="primary" type="submit">Approve agent</button>
                      </form>
                      <form class="inline" method="post" action="/admin/machines/{{ m.id }}/reject" onsubmit="return confirm('Reject agent {{ m.hostname }}?');">
                        <button class="danger" type="submit">Reject</button>
                      </form>
                    {% endif %}

                    '''
    if marker in txt:
        txt = txt.replace(marker, approval_block + marker, 1)

if "Pending approval" not in txt:
    txt = txt.replace(
        '<span class="pill">Security risk {{ ns.security }}</span>',
        '<span class="pill">Security risk {{ ns.security }}</span>\n          <span class="pill">Pending approval {{ machines|selectattr("approved", "equalto", false)|list|length }}</span>'
    )

p.write_text(txt)
PY

echo "[+] Updating .env.example"
if ! grep -q "PATCHPILOT_AUTO_APPROVE_AGENTS" .env.example 2>/dev/null; then
  cat >> .env.example <<'EOF'

# Template approval model:
# false = new agents enroll as pending and must be approved in admin UI
# true  = old behavior, new agents become approved immediately
PATCHPILOT_AUTO_APPROVE_AGENTS=false
EOF
fi

echo
echo "[+] Template approval patch installed."
echo "Backup saved in: ${BACKUP_DIR}"
echo
echo "Rebuild:"
echo "  docker compose up -d --build"
echo
echo "Build a VM template with:"
echo "  curl -fsSL https://patch.labnat.xyz/template-install.sh | sudo bash"
echo
echo "Existing agent binary can be upgraded with:"
echo "  sudo curl -fsSL https://patch.labnat.xyz/agent/patchpilot-agent.py -o /usr/local/bin/patchpilot-agent"
echo "  sudo chmod 755 /usr/local/bin/patchpilot-agent"
echo "  sudo systemctl start patchpilot-agent.service"
