import json
import os
from datetime import datetime, timedelta
from urllib import request as urllib_request
from zoneinfo import ZoneInfo
from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import text
from sqlalchemy.orm import Session
from .db import Base, engine, get_db, SessionLocal
from .models import AuditLog, Group, Job, Machine, MachineGroup, PackageUpdate, Schedule
from .security import hash_token, new_token, verify_token
import hashlib

APP_VERSION = "0.4.0"
ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}
DAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}

Base.metadata.create_all(bind=engine)
app = FastAPI(title="PatchPilot", version=APP_VERSION)
from fastapi.responses import PlainTextResponse
import os

AGENT_PUBLIC_HOSTNAME = os.getenv("AGENT_PUBLIC_HOSTNAME", "patch.labnat.xyz")
ADMIN_INTERNAL_HOSTNAMES = {
    h.strip()
    for h in os.getenv(
        "ADMIN_INTERNAL_HOSTNAMES",
        "patch.labnat.lan,localhost,127.0.0.1"
    ).split(",")
    if h.strip()
}

@app.middleware("http")
async def host_path_guard(request, call_next):
    host = request.headers.get("host", "").split(":")[0].lower()
    path = request.url.path

    # Public Cloudflare hostname: agent endpoints only.
    if host == AGENT_PUBLIC_HOSTNAME.lower():
        allowed = (
            path == "/healthz"
            or path == "/install.sh"
            or path.startswith("/agent/")
            or path.startswith("/api/v1/agent/")
        )

        if not allowed:
            return PlainTextResponse("not found", status_code=404)

    # Internal admin hostnames: block public agent API if you want hard separation.
    if host in {h.lower() for h in ADMIN_INTERNAL_HOSTNAMES}:
        if path.startswith("/api/v1/agent/") or path.startswith("/agent/") or path == "/install.sh":
            return PlainTextResponse("not found", status_code=404)

    return await call_next(request)
templates = Jinja2Templates(directory="app/templates")
scheduler = BackgroundScheduler(timezone="UTC")

def migrate_db():
    statements = [
        "ALTER TABLE machines ADD COLUMN IF NOT EXISTS disabled_reason VARCHAR(255)",
        "ALTER TABLE machines ADD COLUMN IF NOT EXISTS agent_version VARCHAR(64)",
        "ALTER TABLE machines ADD COLUMN IF NOT EXISTS last_error TEXT",
        "ALTER TABLE machines ADD COLUMN IF NOT EXISTS last_job_at TIMESTAMP",
        "ALTER TABLE machines ADD COLUMN IF NOT EXISTS last_success_at TIMESTAMP",
        "ALTER TABLE jobs ADD COLUMN IF NOT EXISTS created_by VARCHAR(128)",
    ]
    with engine.begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))

def audit(db: Session, action: str, actor: str = "admin", target_type: str | None = None, target_id: str | None = None, details: str | None = None, request: Request | None = None):
    ip = request.client.host if request and request.client else None
    db.add(AuditLog(actor=actor, action=action, target_type=target_type, target_id=target_id, ip_address=ip, details=details))

def notify_discord(message: str):
    url = os.getenv("DISCORD_WEBHOOK_URL", "").strip()
    if not url:
        return
    try:
        data = json.dumps({"content": message[:1900]}).encode("utf-8")
        req = urllib_request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
        urllib_request.urlopen(req, timeout=10).read()
    except Exception:
        pass

def machine_state(machine: Machine) -> str:
    if not machine.active:
        return "disabled"
    if not machine.last_seen:
        return "never"
    age = datetime.utcnow() - machine.last_seen
    if age < timedelta(minutes=10):
        return "online"
    if age < timedelta(hours=2):
        return "stale"
    return "offline"


def latest_agent_info():
    agent_path = "app/static/patchpilot-agent.py"
    try:
        with open(agent_path, "rb") as f:
            data = f.read()
        content = data.decode("utf-8", errors="replace")
        m = re.search(r'AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', content)
        version = m.group(1) if m else "unknown"
        sha256 = hashlib.sha256(data).hexdigest()
        public_url = os.getenv("PUBLIC_AGENT_URL", "").rstrip("/")
        update_url = f"{public_url}/agent/patchpilot-agent.py" if public_url else "/agent/patchpilot-agent.py"
        return {"version": version, "sha256": sha256, "url": update_url}
    except Exception:
        return {"version": "unknown", "sha256": "", "url": "/agent/patchpilot-agent.py"}

def version_tuple(v: str):
    try:
        return tuple(int(x) for x in re.findall(r"\d+", v)[:3])
    except Exception:
        return (0, 0, 0)

def agent_is_outdated(current: str | None, latest: str | None) -> bool:
    if not current or not latest or latest == "unknown":
        return False
    return version_tuple(current) < version_tuple(latest)

def get_agent(db: Session, x_agent_id: str | None, authorization: str | None) -> Machine:
    if not x_agent_id or not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing agent auth")
    token = authorization.replace("Bearer ", "", 1).strip()
    machine = db.query(Machine).filter(Machine.machine_id == x_agent_id).first()
    if not machine or not machine.active:
        raise HTTPException(status_code=401, detail="Unknown or inactive agent")
    if not verify_token(token, machine.token_hash):
        raise HTTPException(status_code=401, detail="Bad agent token")
    return machine

def targets_for_schedule(db: Session, schedule: Schedule) -> list[Machine]:
    if schedule.target_type == "machine":
        m = db.query(Machine).filter(Machine.id == schedule.target_id, Machine.active == True).first()
        return [m] if m else []
    if schedule.target_type == "group":
        return db.query(Machine).join(MachineGroup, MachineGroup.machine_id == Machine.id).filter(MachineGroup.group_id == schedule.target_id, Machine.active == True).all()
    return []

def run_schedules():
    db = SessionLocal()
    try:
        for s in db.query(Schedule).filter(Schedule.enabled == True).all():
            try:
                tz = ZoneInfo(s.timezone or "Europe/Stockholm")
            except Exception:
                tz = ZoneInfo("Europe/Stockholm")
            now = datetime.now(tz)
            if s.time_of_day != now.strftime("%H:%M"):
                continue
            if s.day_of_week != "all" and DAYS.get(s.day_of_week) != now.weekday():
                continue
            run_key = f"{s.id}-{now.strftime('%Y%m%d-%H%M')}"
            if s.last_run_key == run_key:
                continue
            created = 0
            for m in targets_for_schedule(db, s):
                existing = db.query(Job).filter(Job.machine_id == m.id, Job.status.in_(["pending", "running", "approval_required"])).first()
                if existing:
                    continue
                db.add(Job(machine_id=m.id, action=s.action, status="approval_required" if s.require_approval else "pending", allow_reboot=s.allow_reboot, created_by=f"schedule:{s.name}"))
                created += 1
            s.last_run_key = run_key
            s.last_run_at = datetime.utcnow()
            audit(db, "schedule_run", actor="system", target_type="schedule", target_id=str(s.id), details=f"created_jobs={created}")
            db.commit()
            if created:
                notify_discord(f"PatchPilot: schedule '{s.name}' created {created} job(s).")
    except Exception as e:
        db.rollback()
        notify_discord(f"PatchPilot scheduler error: {e}")
    finally:
        db.close()

migrate_db()

@app.on_event("startup")
def startup():
    if not scheduler.running:
        scheduler.add_job(run_schedules, "interval", seconds=60, id="patchpilot_scheduler", replace_existing=True)
        scheduler.start()

@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    return "ok"

@app.get("/", response_class=HTMLResponse)
def root():
    return RedirectResponse("/admin")

@app.get("/admin", response_class=HTMLResponse)
def admin(request: Request, db: Session = Depends(get_db)):
    machines = db.query(Machine).order_by(Machine.hostname.asc()).all()
    jobs = db.query(Job).order_by(Job.created_at.desc()).limit(50).all()
    groups = db.query(Group).order_by(Group.name.asc()).all()
    schedules = db.query(Schedule).order_by(Schedule.name.asc()).all()
    machine_groups = db.query(MachineGroup).all()
    packages = db.query(PackageUpdate).order_by(PackageUpdate.created_at.desc()).limit(100).all()
    audits = db.query(AuditLog).order_by(AuditLog.created_at.desc()).limit(30).all()
    group_map = {}
    for mg in machine_groups:
        group_map.setdefault(mg.machine_id, []).append(mg.group_id)
    return templates.TemplateResponse("admin.html", {"request": request, "version": APP_VERSION, "machines": machines, "jobs": jobs, "groups": groups, "schedules": schedules, "packages": packages, "audits": audits, "group_map": group_map, "machine_state": machine_state})

@app.post("/admin/machines/{machine_pk}/jobs")
def create_job(machine_pk: int, action: str = Form(...), allow_reboot: bool = Form(False), db: Session = Depends(get_db), request: Request = None):
    if action not in ALLOWED_ACTIONS:
        raise HTTPException(status_code=400, detail="Invalid action")
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    db.add(Job(machine_id=machine.id, action=action, allow_reboot=allow_reboot, status="pending", created_by="admin"))
    audit(db, "job_created", target_type="machine", target_id=str(machine.id), details=f"action={action}", request=request)
    db.commit()
    notify_discord(f"PatchPilot: job '{action}' queued for {machine.hostname}.")
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/jobs/{job_id}/approve")
def approve_job(job_id: int, db: Session = Depends(get_db), request: Request = None):
    job = db.query(Job).filter(Job.id == job_id).first()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    job.status = "pending"
    audit(db, "job_approved", target_type="job", target_id=str(job.id), request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/jobs/{job_id}/delete")
def delete_job(job_id: int, db: Session = Depends(get_db), request: Request = None):
    job = db.query(Job).filter(Job.id == job_id).first()
    if job:
        audit(db, "job_deleted", target_type="job", target_id=str(job.id), request=request)
        db.delete(job)
        db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/machines/{machine_pk}/settings")
def update_machine_settings(machine_pk: int, auto_patch: bool = Form(False), auto_reboot: bool = Form(False), db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    machine.auto_patch = auto_patch
    machine.auto_reboot = auto_reboot
    audit(db, "machine_settings_updated", target_type="machine", target_id=str(machine.id), request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/machines/{machine_pk}/disable")
def disable_machine(machine_pk: int, reason: str = Form("disabled by admin"), db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    machine.active = False
    machine.disabled_reason = reason
    audit(db, "machine_disabled", target_type="machine", target_id=str(machine.id), details=reason, request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/machines/{machine_pk}/enable")
def enable_machine(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    machine.active = True
    machine.disabled_reason = None
    audit(db, "machine_enabled", target_type="machine", target_id=str(machine.id), request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/machines/{machine_pk}/rotate-token")
def rotate_machine_token(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    token = new_token("pp_agent")
    machine.token_hash = hash_token(token)
    audit(db, "machine_token_rotated", target_type="machine", target_id=str(machine.id), request=request)
    db.commit()
    return PlainTextResponse(f"New token for {machine.hostname}:\n\n{token}\n\nUpdate /etc/patchpilot/agent.json on the client manually.\n")

@app.post("/admin/machines/{machine_pk}/delete")
def delete_machine(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")
    db.query(Job).filter(Job.machine_id == machine.id).delete()
    db.query(PackageUpdate).filter(PackageUpdate.machine_id == machine.id).delete()
    db.query(MachineGroup).filter(MachineGroup.machine_id == machine.id).delete()
    audit(db, "machine_deleted", target_type="machine", target_id=str(machine.id), details=machine.hostname, request=request)
    db.delete(machine)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/machines/{machine_pk}/delete-jobs")
def delete_machine_jobs(machine_pk: int, db: Session = Depends(get_db), request: Request = None):
    deleted = db.query(Job).filter(Job.machine_id == machine_pk).delete()
    audit(db, "machine_jobs_deleted", target_type="machine", target_id=str(machine_pk), details=f"deleted={deleted}", request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/groups")
def create_group(name: str = Form(...), description: str = Form(""), db: Session = Depends(get_db), request: Request = None):
    if db.query(Group).filter(Group.name == name).first():
        raise HTTPException(status_code=409, detail="Group already exists")
    db.add(Group(name=name.strip(), description=description.strip() or None))
    audit(db, "group_created", target_type="group", target_id=name, request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/groups/{group_id}/delete")
def delete_group(group_id: int, db: Session = Depends(get_db), request: Request = None):
    db.query(MachineGroup).filter(MachineGroup.group_id == group_id).delete()
    group = db.query(Group).filter(Group.id == group_id).first()
    if group:
        audit(db, "group_deleted", target_type="group", target_id=str(group_id), details=group.name, request=request)
        db.delete(group)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/groups/assign")
def assign_group(machine_id: int = Form(...), group_id: int = Form(...), db: Session = Depends(get_db), request: Request = None):
    if not db.query(MachineGroup).filter(MachineGroup.machine_id == machine_id, MachineGroup.group_id == group_id).first():
        db.add(MachineGroup(machine_id=machine_id, group_id=group_id))
        audit(db, "machine_added_to_group", target_type="machine", target_id=str(machine_id), details=f"group_id={group_id}", request=request)
        db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/groups/unassign")
def unassign_group(machine_id: int = Form(...), group_id: int = Form(...), db: Session = Depends(get_db), request: Request = None):
    db.query(MachineGroup).filter(MachineGroup.machine_id == machine_id, MachineGroup.group_id == group_id).delete()
    audit(db, "machine_removed_from_group", target_type="machine", target_id=str(machine_id), details=f"group_id={group_id}", request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/schedules")
def create_schedule(name: str = Form(...), target_type: str = Form(...), target_id: int = Form(...), action: str = Form(...), day_of_week: str = Form("all"), time_of_day: str = Form("03:00"), timezone: str = Form("Europe/Stockholm"), allow_reboot: bool = Form(False), require_approval: bool = Form(False), enabled: bool = Form(False), db: Session = Depends(get_db), request: Request = None):
    if action not in ALLOWED_ACTIONS or target_type not in {"machine", "group"} or day_of_week not in {"all", "mon", "tue", "wed", "thu", "fri", "sat", "sun"}:
        raise HTTPException(status_code=400, detail="Invalid schedule")
    s = Schedule(name=name.strip(), target_type=target_type, target_id=target_id, action=action, day_of_week=day_of_week, time_of_day=time_of_day, timezone=timezone, allow_reboot=allow_reboot, require_approval=require_approval, enabled=enabled)
    db.add(s)
    audit(db, "schedule_created", target_type="schedule", target_id=name, request=request)
    db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/admin/schedules/{schedule_id}/delete")
def delete_schedule(schedule_id: int, db: Session = Depends(get_db), request: Request = None):
    s = db.query(Schedule).filter(Schedule.id == schedule_id).first()
    if s:
        audit(db, "schedule_deleted", target_type="schedule", target_id=str(s.id), details=s.name, request=request)
        db.delete(s)
        db.commit()
    return RedirectResponse("/admin", status_code=303)

@app.post("/api/v1/agent/enroll")
def enroll_agent(payload: dict, request: Request, db: Session = Depends(get_db)):
    machine_id = payload.get("machine_id")
    hostname = payload.get("hostname")
    if not machine_id or not hostname:
        raise HTTPException(status_code=400, detail="machine_id and hostname required")
    if db.query(Machine).filter(Machine.machine_id == machine_id).first():
        raise HTTPException(status_code=409, detail="machine already enrolled")
    token = new_token("pp_agent")
    machine = Machine(machine_id=machine_id, hostname=hostname, token_hash=hash_token(token), ip_address=request.client.host if request.client else None, last_seen=datetime.utcnow(), active=True)
    db.add(machine)
    audit(db, "agent_enrolled", actor="agent", target_type="machine", target_id=machine_id, request=request)
    db.commit()
    notify_discord(f"PatchPilot: new agent enrolled: {hostname} ({machine_id})")
    return {"machine_id": machine_id, "agent_token": token, "status": "enrolled"}

@app.post("/api/v1/agent/checkin")
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

    jobs = (
        db.query(Job)
        .filter(Job.machine_id == machine.id, Job.status == "pending")
        .order_by(Job.created_at.asc())
        .limit(3)
        .all()
    )

    latest = latest_agent_info()
    auto_agent_update = os.getenv("PATCHPILOT_AUTO_AGENT_UPDATE", "false").lower() in {"1", "true", "yes", "on"}

    return {
        "status": "ok",
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
            "outdated": agent_is_outdated(machine.agent_version, latest["version"]),
        },
        "jobs": [{"id": job.id, "action": job.action, "allow_reboot": job.allow_reboot} for job in jobs],
    }

@app.post("/api/v1/agent/jobs/{job_id}/started")
def job_started(job_id: int, x_agent_id: str | None = Header(default=None), authorization: str | None = Header(default=None), db: Session = Depends(get_db)):
    machine = get_agent(db, x_agent_id, authorization)
    job = db.query(Job).filter(Job.id == job_id, Job.machine_id == machine.id).first()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    job.status = "running"
    job.started_at = datetime.utcnow()
    machine.last_job_at = datetime.utcnow()
    db.commit()
    return {"status": "ok"}

@app.post("/api/v1/agent/jobs/{job_id}/result")
def job_result(job_id: int, payload: dict, x_agent_id: str | None = Header(default=None), authorization: str | None = Header(default=None), db: Session = Depends(get_db)):
    machine = get_agent(db, x_agent_id, authorization)
    job = db.query(Job).filter(Job.id == job_id, Job.machine_id == machine.id).first()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    exit_code = int(payload.get("exit_code", 1))
    job.status = "success" if exit_code == 0 else "failed"
    job.exit_code = exit_code
    job.output = str(payload.get("output", ""))[:30000]
    job.finished_at = datetime.utcnow()
    machine.last_job_at = datetime.utcnow()
    if exit_code == 0:
        machine.last_success_at = datetime.utcnow()
    else:
        machine.last_error = job.output[:5000]
    audit(db, "job_result", actor="agent", target_type="job", target_id=str(job.id), details=f"status={job.status}")
    db.commit()
    if exit_code != 0:
        notify_discord(f"PatchPilot: job {job.action} failed on {machine.hostname}.")
    elif job.action in {"upgrade", "security_upgrade", "reboot"}:
        notify_discord(f"PatchPilot: job {job.action} completed on {machine.hostname}.")
    return {"status": "ok"}


@app.get("/api/v1/agent/latest")
def agent_latest():
    return latest_agent_info()

@app.get("/agent/patchpilot-agent.py", response_class=PlainTextResponse)
def download_agent():
    with open("app/static/patchpilot-agent.py", "r", encoding="utf-8") as f:
        return PlainTextResponse(f.read(), media_type="text/x-python; charset=utf-8", headers={"Cache-Control": "no-store"})

@app.get("/install.sh", response_class=PlainTextResponse)
def install_agent_script(request: Request):
    detected_server_url = os.getenv("PUBLIC_AGENT_URL", str(request.base_url).rstrip("/")).rstrip("/")
    script = f'''#!/usr/bin/env bash
set -euo pipefail
SERVER_URL="{detected_server_url}"
AGENT_URL="$SERVER_URL/agent/patchpilot-agent.py"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_URL="$2"; AGENT_URL="$SERVER_URL/agent/patchpilot-agent.py"; shift 2 ;;
    --agent-url) AGENT_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done
if [[ "$EUID" -ne 0 ]]; then echo "ERROR: Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
echo "[+] PatchPilot agent installer"
echo "[+] Server URL: $SERVER_URL"
apt-get update
apt-get install -y python3 ca-certificates unattended-upgrades curl
install -d -m 700 /etc/patchpilot
curl -fsSL "$AGENT_URL" -o /usr/local/bin/patchpilot-agent
chmod 755 /usr/local/bin/patchpilot-agent
/usr/local/bin/patchpilot-agent --enroll --server "$SERVER_URL"
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
systemctl enable --now patchpilot-agent.timer
systemctl start patchpilot-agent.service || true
echo "[+] Done. Config: /etc/patchpilot/agent.json"
'''
    return PlainTextResponse(script, media_type="text/x-shellscript; charset=utf-8", headers={"Cache-Control": "no-store"})
