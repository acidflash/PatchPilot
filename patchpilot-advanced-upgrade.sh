#!/usr/bin/env bash
set -euo pipefail

# PatchPilot advanced upgrade
# Run from inside existing patchpilot project directory:
#   cd patchpilot
#   bash patchpilot-advanced-upgrade.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/main.py" ]]; then
  echo "ERROR: Run this from inside the patchpilot project directory."
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="_backup_advanced_${TS}"

mkdir -p "${BACKUP_DIR}"
cp -a backend "${BACKUP_DIR}/backend"
cp -a agent "${BACKUP_DIR}/agent" 2>/dev/null || true

mkdir -p backend/app/templates backend/app/static agent

cat > backend/requirements.txt <<'REQ'
fastapi==0.115.6
uvicorn[standard]==0.34.0
sqlalchemy==2.0.36
psycopg2-binary==2.9.10
jinja2==3.1.5
python-multipart==0.0.20
pydantic==2.10.4
passlib==1.7.4
bcrypt==4.0.1
apscheduler==3.11.0
REQ

cat > backend/app/models.py <<'PY'
from datetime import datetime
from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship
from .db import Base

class Machine(Base):
    __tablename__ = "machines"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    machine_id: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    hostname: Mapped[str] = mapped_column(String(255), index=True)
    token_hash: Mapped[str] = mapped_column(String(255))
    os_version: Mapped[str | None] = mapped_column(String(255), nullable=True)
    kernel_version: Mapped[str | None] = mapped_column(String(255), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(String(64), nullable=True)
    updates_available: Mapped[int] = mapped_column(Integer, default=0)
    security_updates_available: Mapped[int] = mapped_column(Integer, default=0)
    reboot_required: Mapped[bool] = mapped_column(Boolean, default=False)
    auto_patch: Mapped[bool] = mapped_column(Boolean, default=False)
    auto_reboot: Mapped[bool] = mapped_column(Boolean, default=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    disabled_reason: Mapped[str | None] = mapped_column(String(255), nullable=True)
    agent_version: Mapped[str | None] = mapped_column(String(64), nullable=True)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    last_seen: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    last_job_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    last_success_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    jobs = relationship("Job", back_populates="machine")
    packages = relationship("PackageUpdate", back_populates="machine", cascade="all, delete-orphan")

class Job(Base):
    __tablename__ = "jobs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    machine_id: Mapped[int] = mapped_column(Integer, ForeignKey("machines.id"))
    action: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(64), default="pending")
    allow_reboot: Mapped[bool] = mapped_column(Boolean, default=False)
    output: Mapped[str | None] = mapped_column(Text, nullable=True)
    exit_code: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    machine = relationship("Machine", back_populates="jobs")

class Group(Base):
    __tablename__ = "groups"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    name: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    description: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

class MachineGroup(Base):
    __tablename__ = "machine_groups"
    __table_args__ = (UniqueConstraint("machine_id", "group_id", name="uq_machine_group"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    machine_id: Mapped[int] = mapped_column(Integer, ForeignKey("machines.id"), index=True)
    group_id: Mapped[int] = mapped_column(Integer, ForeignKey("groups.id"), index=True)

class PackageUpdate(Base):
    __tablename__ = "package_updates"
    __table_args__ = (UniqueConstraint("machine_id", "package", name="uq_machine_package_update"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    machine_id: Mapped[int] = mapped_column(Integer, ForeignKey("machines.id"), index=True)
    package: Mapped[str] = mapped_column(String(255), index=True)
    current_version: Mapped[str | None] = mapped_column(String(255), nullable=True)
    candidate_version: Mapped[str | None] = mapped_column(String(255), nullable=True)
    security: Mapped[bool] = mapped_column(Boolean, default=False)
    raw: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    machine = relationship("Machine", back_populates="packages")

class Schedule(Base):
    __tablename__ = "schedules"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(128), index=True)
    target_type: Mapped[str] = mapped_column(String(32), default="machine")
    target_id: Mapped[int] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(64), default="upgrade")
    day_of_week: Mapped[str] = mapped_column(String(16), default="all")
    time_of_day: Mapped[str] = mapped_column(String(5), default="03:00")
    timezone: Mapped[str] = mapped_column(String(64), default="Europe/Stockholm")
    allow_reboot: Mapped[bool] = mapped_column(Boolean, default=False)
    require_approval: Mapped[bool] = mapped_column(Boolean, default=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    last_run_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    last_run_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

class AuditLog(Base):
    __tablename__ = "audit_logs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    actor: Mapped[str] = mapped_column(String(128), default="system")
    action: Mapped[str] = mapped_column(String(128))
    target_type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    target_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(String(64), nullable=True)
    details: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
PY

cat > backend/app/main.py <<'PY'
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

APP_VERSION = "0.3.0"
ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean"}
DAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}

Base.metadata.create_all(bind=engine)
app = FastAPI(title="PatchPilot", version=APP_VERSION)
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
def checkin(payload: dict, request: Request, x_agent_id: str | None = Header(default=None), authorization: str | None = Header(default=None), db: Session = Depends(get_db)):
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
            if isinstance(pkg, dict) and pkg.get("package"):
                db.add(PackageUpdate(machine_id=machine.id, package=str(pkg.get("package"))[:255], current_version=str(pkg.get("current_version") or "")[:255] or None, candidate_version=str(pkg.get("candidate_version") or "")[:255] or None, security=bool(pkg.get("security", False)), raw=str(pkg.get("raw") or "")[:2000] or None))
    db.commit()
    jobs = db.query(Job).filter(Job.machine_id == machine.id, Job.status == "pending").order_by(Job.created_at.asc()).limit(3).all()
    return {"status": "ok", "policy": {"auto_patch": machine.auto_patch, "auto_reboot": machine.auto_reboot}, "jobs": [{"id": job.id, "action": job.action, "allow_reboot": job.allow_reboot} for job in jobs]}

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
PY

cat > backend/app/templates/admin.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>PatchPilot</title>
  <style>
    body { font-family: Arial, sans-serif; background: #101318; color: #e8e8e8; margin: 24px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 30px; background: #181d25; }
    th, td { border: 1px solid #2e3642; padding: 8px; text-align: left; vertical-align: top; }
    th { background: #222a35; } input, select, button { padding: 6px; margin: 2px; }
    button { cursor: pointer; border-radius: 4px; border: 1px solid #384252; background: #222a35; color: #fff; }
    code { color: #c7d2fe; } pre { white-space: pre-wrap; max-height: 120px; overflow: auto; }
    .ok { color: #74d680; } .warn { color: #ffd166; } .bad { color: #ff6b6b; } .muted { color: #9aa4b2; }
    .box { background: #181d25; padding: 15px; border: 1px solid #2e3642; margin-bottom: 20px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; } .danger { background: #7f1d1d; color: #fff; border: 1px solid #991b1b; }
    .small { font-size: 12px; }
  </style>
</head>
<body>
  <h1>PatchPilot <span class="muted small">v{{ version }}</span></h1>

  <h2>Machines</h2>
  <table>
    <tr><th>State</th><th>Hostname</th><th>Machine ID</th><th>Agent</th><th>OS / Kernel</th><th>Updates</th><th>Reboot</th><th>Groups</th><th>Last seen</th><th>Actions</th></tr>
    {% for m in machines %}{% set st = machine_state(m) %}
    <tr>
      <td class="{{ 'ok' if st == 'online' else 'warn' if st == 'stale' else 'bad' if st == 'offline' else 'muted' }}">{{ st }}</td>
      <td>{{ m.hostname }}{% if not m.active %}<br><span class="muted small">{{ m.disabled_reason }}</span>{% endif %}</td>
      <td><code>{{ m.machine_id }}</code></td>
      <td>{{ m.agent_version or "-" }}{% if m.last_error %}<br><span class="bad small">{{ m.last_error[:120] }}</span>{% endif %}</td>
      <td>{{ m.os_version or "-" }}<br><span class="muted small">{{ m.kernel_version or "-" }}</span></td>
      <td>Total: <span class="{{ 'warn' if m.updates_available else 'ok' }}">{{ m.updates_available }}</span><br>Security: <span class="{{ 'bad' if m.security_updates_available else 'ok' }}">{{ m.security_updates_available }}</span></td>
      <td class="{{ 'bad' if m.reboot_required else 'ok' }}">{{ "required" if m.reboot_required else "no" }}</td>
      <td>{% for g in groups %}{% if m.id in group_map and g.id in group_map[m.id] %}{{ g.name }}<br>{% endif %}{% endfor %}</td>
      <td>{{ m.last_seen or "-" }}<br><span class="muted small">success: {{ m.last_success_at or "-" }}</span></td>
      <td>
        <form method="post" action="/admin/machines/{{ m.id }}/jobs"><select name="action"><option value="check_updates">check</option><option value="upgrade">upgrade</option><option value="security_upgrade">security upgrade</option><option value="reboot">reboot</option><option value="apt_clean">apt clean</option></select><label><input type="checkbox" name="allow_reboot" value="true"> reboot</label><button type="submit">queue</button></form>
        <form method="post" action="/admin/machines/{{ m.id }}/settings"><label><input type="checkbox" name="auto_patch" value="true" {% if m.auto_patch %}checked{% endif %}> auto patch</label><label><input type="checkbox" name="auto_reboot" value="true" {% if m.auto_reboot %}checked{% endif %}> auto reboot</label><button type="submit">save</button></form>
        {% if m.active %}<form method="post" action="/admin/machines/{{ m.id }}/disable"><input name="reason" value="disabled by admin"><button type="submit">disable</button></form>{% else %}<form method="post" action="/admin/machines/{{ m.id }}/enable"><button type="submit">enable</button></form>{% endif %}
        <form method="post" action="/admin/machines/{{ m.id }}/delete-jobs" onsubmit="return confirm('Delete all jobs for {{ m.hostname }}?');"><button type="submit">clear jobs</button></form>
        <form method="post" action="/admin/machines/{{ m.id }}/rotate-token" onsubmit="return confirm('Rotate token for {{ m.hostname }}?');"><button type="submit">rotate token</button></form>
        <form method="post" action="/admin/machines/{{ m.id }}/delete" onsubmit="return confirm('Delete agent {{ m.hostname }} and all its data?');"><button type="submit" class="danger">delete agent</button></form>
      </td>
    </tr>{% endfor %}
  </table>

  <div class="grid">
    <div class="box"><h2>Groups</h2>
      <form method="post" action="/admin/groups"><input name="name" placeholder="group name" required><input name="description" placeholder="description"><button type="submit">create group</button></form>
      <form method="post" action="/admin/groups/assign"><select name="machine_id">{% for m in machines %}<option value="{{ m.id }}">{{ m.hostname }}</option>{% endfor %}</select><select name="group_id">{% for g in groups %}<option value="{{ g.id }}">{{ g.name }}</option>{% endfor %}</select><button type="submit">assign</button></form>
      <form method="post" action="/admin/groups/unassign"><select name="machine_id">{% for m in machines %}<option value="{{ m.id }}">{{ m.hostname }}</option>{% endfor %}</select><select name="group_id">{% for g in groups %}<option value="{{ g.id }}">{{ g.name }}</option>{% endfor %}</select><button type="submit">unassign</button></form>
      <table><tr><th>ID</th><th>Name</th><th>Description</th><th>Action</th></tr>{% for g in groups %}<tr><td>{{ g.id }}</td><td>{{ g.name }}</td><td>{{ g.description or "" }}</td><td><form method="post" action="/admin/groups/{{ g.id }}/delete"><button class="danger">delete</button></form></td></tr>{% endfor %}</table>
    </div>
    <div class="box"><h2>Schedules</h2>
      <form method="post" action="/admin/schedules"><input name="name" placeholder="schedule name" required><select name="target_type"><option value="machine">machine</option><option value="group">group</option></select><input name="target_id" placeholder="target id" required><select name="action"><option value="check_updates">check</option><option value="upgrade">upgrade</option><option value="security_upgrade">security upgrade</option><option value="apt_clean">apt clean</option><option value="reboot">reboot</option></select><select name="day_of_week"><option value="all">daily</option><option value="mon">mon</option><option value="tue">tue</option><option value="wed">wed</option><option value="thu">thu</option><option value="fri">fri</option><option value="sat">sat</option><option value="sun">sun</option></select><input name="time_of_day" value="03:00" style="width:70px"><input name="timezone" value="Europe/Stockholm" style="width:130px"><label><input type="checkbox" name="allow_reboot" value="true"> reboot</label><label><input type="checkbox" name="require_approval" value="true"> approval</label><label><input type="checkbox" name="enabled" value="true" checked> enabled</label><button type="submit">create</button></form>
      <p class="muted small">Target ID är machine id eller group id från tabellerna.</p>
      <table><tr><th>ID</th><th>Name</th><th>Target</th><th>Action</th><th>When</th><th>Flags</th><th>Last run</th><th>Action</th></tr>{% for s in schedules %}<tr><td>{{ s.id }}</td><td>{{ s.name }}</td><td>{{ s.target_type }}:{{ s.target_id }}</td><td>{{ s.action }}</td><td>{{ s.day_of_week }} {{ s.time_of_day }} {{ s.timezone }}</td><td>{% if s.enabled %}enabled{% else %}disabled{% endif %}{% if s.allow_reboot %}, reboot{% endif %}{% if s.require_approval %}, approval{% endif %}</td><td>{{ s.last_run_at or "-" }}</td><td><form method="post" action="/admin/schedules/{{ s.id }}/delete"><button class="danger">delete</button></form></td></tr>{% endfor %}</table>
    </div>
  </div>

  <h2>Latest jobs</h2><table><tr><th>ID</th><th>Machine</th><th>Action</th><th>Status</th><th>Exit</th><th>Created</th><th>Output</th><th>Action</th></tr>{% for j in jobs %}<tr><td>{{ j.id }}</td><td>{{ j.machine.hostname if j.machine else "-" }}</td><td>{{ j.action }}</td><td class="{{ 'ok' if j.status == 'success' else 'bad' if j.status == 'failed' else 'warn' }}">{{ j.status }}</td><td>{{ j.exit_code if j.exit_code is not none else "-" }}</td><td>{{ j.created_at }}<br><span class="muted small">{{ j.created_by or "" }}</span></td><td><pre>{{ j.output or "" }}</pre></td><td>{% if j.status == 'approval_required' %}<form method="post" action="/admin/jobs/{{ j.id }}/approve"><button>approve</button></form>{% endif %}<form method="post" action="/admin/jobs/{{ j.id }}/delete"><button class="danger">delete</button></form></td></tr>{% endfor %}</table>
  <h2>Package updates</h2><table><tr><th>Machine</th><th>Package</th><th>Current</th><th>Candidate</th><th>Security</th></tr>{% for p in packages %}<tr><td>{{ p.machine.hostname if p.machine else "-" }}</td><td>{{ p.package }}</td><td>{{ p.current_version or "-" }}</td><td>{{ p.candidate_version or "-" }}</td><td class="{{ 'bad' if p.security else 'muted' }}">{{ "yes" if p.security else "no" }}</td></tr>{% endfor %}</table>
  <h2>Audit log</h2><table><tr><th>Time</th><th>Actor</th><th>Action</th><th>Target</th><th>Details</th></tr>{% for a in audits %}<tr><td>{{ a.created_at }}</td><td>{{ a.actor }}</td><td>{{ a.action }}</td><td>{{ a.target_type or "" }} {{ a.target_id or "" }}</td><td>{{ a.details or "" }}</td></tr>{% endfor %}</table>
</body></html>
HTML

cat > agent/patchpilot-agent.py <<'PY'
#!/usr/bin/env python3
import argparse, json, os, platform, re, socket, subprocess, sys, uuid
from pathlib import Path
from urllib import request, error
AGENT_VERSION = "0.3.0"
CONFIG_PATH = Path("/etc/patchpilot/agent.json")
ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean"}

def run(cmd, timeout=1800):
    env = os.environ.copy(); env["DEBIAN_FRONTEND"] = "noninteractive"; env["NEEDRESTART_MODE"] = "a"
    p = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout, env=env)
    return p.returncode, (p.stdout + "\n" + p.stderr).strip()

def load_config():
    if not CONFIG_PATH.exists(): print(f"Missing config: {CONFIG_PATH}", file=sys.stderr); sys.exit(1)
    return json.loads(CONFIG_PATH.read_text())

def save_config(cfg):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True); CONFIG_PATH.write_text(json.dumps(cfg, indent=2)); os.chmod(CONFIG_PATH, 0o600)

def http_json(method, url, data=None, headers=None):
    body = json.dumps(data).encode() if data is not None else None
    h = {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": f"PatchPilot-Agent/{AGENT_VERSION}"}
    if headers: h.update(headers)
    req = request.Request(url, data=body, method=method, headers=h)
    try:
        with request.urlopen(req, timeout=90) as resp:
            raw = resp.read().decode(); return json.loads(raw) if raw else {}
    except error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.read().decode()}", file=sys.stderr); raise

def get_machine_id():
    p = Path("/etc/patchpilot/machine-id")
    if p.exists(): return p.read_text().strip()
    mid = f"{socket.gethostname()}-{uuid.uuid4().hex[:12]}"; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(mid); os.chmod(p, 0o600); return mid

def parse_apt_updates():
    rc, out = run("apt list --upgradable 2>/dev/null | tail -n +2", timeout=180)
    pkgs = []
    if rc != 0: return pkgs
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        name = line.split("/", 1)[0]; parts = line.split(); cand = parts[1] if len(parts) >= 2 else None
        m = re.search(r"\[upgradable from:\s*([^\]]+)\]", line)
        pkgs.append({"package": name, "current_version": m.group(1) if m else None, "candidate_version": cand, "security": "security" in line.lower(), "raw": line})
    return pkgs

def apt_check_counts(packages):
    updates, security = len(packages), len([p for p in packages if p.get("security")])
    if Path("/usr/lib/update-notifier/apt-check").exists():
        rc, out = run("/usr/lib/update-notifier/apt-check 2>/dev/null || true", timeout=120)
        m = re.search(r"(\d+)\s*;\s*(\d+)", out)
        if m: updates, security = int(m.group(1)), int(m.group(2))
    return updates, security

def collect_status(last_error=None):
    run("apt-get update", timeout=900)
    packages = parse_apt_updates(); updates, security = apt_check_counts(packages)
    os_version = ""
    if Path("/etc/os-release").exists():
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="): os_version = line.split("=", 1)[1].strip('"'); break
    return {"hostname": socket.gethostname(), "os_version": os_version, "kernel_version": platform.release(), "agent_version": AGENT_VERSION, "updates_available": updates, "security_updates_available": security, "reboot_required": Path("/var/run/reboot-required").exists(), "packages": packages, "last_error": last_error}

def auth_headers(cfg): return {"X-Agent-ID": cfg["machine_id"], "Authorization": f"Bearer {cfg['agent_token']}"}

def enroll(server_url):
    mid = get_machine_id(); resp = http_json("POST", f"{server_url.rstrip('/')}/api/v1/agent/enroll", {"machine_id": mid, "hostname": socket.gethostname()})
    save_config({"server_url": server_url.rstrip("/"), "machine_id": mid, "agent_token": resp["agent_token"]}); print(f"Enrolled as {mid}")

def execute_job(job):
    action = job.get("action"); allow_reboot = bool(job.get("allow_reboot", False))
    if action not in ALLOWED_ACTIONS: return 1, f"Refused invalid action: {action}"
    if action == "check_updates": return 0, json.dumps(collect_status(), indent=2)
    if action == "upgrade":
        rc, out = run("apt-get update && apt-get upgrade -y", timeout=7200)
        if rc == 0 and allow_reboot and Path("/var/run/reboot-required").exists(): run("systemctl reboot", timeout=10)
        return rc, out
    if action == "security_upgrade":
        rc, out = run("apt-get update && unattended-upgrade -d", timeout=7200)
        if rc == 0 and allow_reboot and Path("/var/run/reboot-required").exists(): run("systemctl reboot", timeout=10)
        return rc, out
    if action == "reboot":
        if not allow_reboot: return 1, "Reboot refused because allow_reboot is false"
        run("systemctl reboot", timeout=10); return 0, "Reboot requested"
    if action == "apt_clean": return run("apt-get autoremove -y && apt-get autoclean -y", timeout=1800)
    return 1, "Unhandled action"

def run_once():
    cfg = load_config(); server = cfg["server_url"].rstrip("/")
    try:
        resp = http_json("POST", f"{server}/api/v1/agent/checkin", collect_status(), auth_headers(cfg))
        for job in resp.get("jobs", []):
            jid = job["id"]; http_json("POST", f"{server}/api/v1/agent/jobs/{jid}/started", {}, auth_headers(cfg))
            exit_code, output = execute_job(job)
            http_json("POST", f"{server}/api/v1/agent/jobs/{jid}/result", {"exit_code": exit_code, "output": output}, auth_headers(cfg))
    except Exception as e:
        try: http_json("POST", f"{server}/api/v1/agent/checkin", collect_status(last_error=str(e)), auth_headers(cfg))
        except Exception: pass
        raise

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--enroll", action="store_true"); parser.add_argument("--server"); parser.add_argument("--once", action="store_true"); args = parser.parse_args()
    if args.enroll:
        if not args.server: print("--server is required with --enroll", file=sys.stderr); sys.exit(1)
        enroll(args.server)
    else: run_once()
PY
chmod +x agent/patchpilot-agent.py
cp agent/patchpilot-agent.py backend/app/static/patchpilot-agent.py
chmod 644 backend/app/static/patchpilot-agent.py

if ! grep -q "DISCORD_WEBHOOK_URL" .env.example 2>/dev/null; then
  cat >> .env.example <<'ENV'

# Optional Discord alerts
DISCORD_WEBHOOK_URL=
ENV
fi

echo "[+] Advanced upgrade complete. Backup saved in: ${BACKUP_DIR}"
echo "[+] Rebuild: docker compose up -d --build"
echo "[+] Upgrade clients: sudo curl -fsSL https://patch.labnat.xyz/agent/patchpilot-agent.py -o /usr/local/bin/patchpilot-agent && sudo chmod 755 /usr/local/bin/patchpilot-agent && sudo systemctl start patchpilot-agent.service"
