#!/usr/bin/env bash
set -euo pipefail

# PatchPilot agent self-update upgrade v2
# More tolerant patcher for already modified main.py.
#
# Run:
#   cd patchpilot
#   bash patchpilot-add-agent-selfupdate-v2.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/main.py" ]]; then
  echo "ERROR: Run this from inside the patchpilot project directory."
  exit 1
fi

if [[ ! -f "agent/patchpilot-agent.py" ]]; then
  echo "ERROR: Missing agent/patchpilot-agent.py"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="_backup_selfupdate_v2_${TS}"

echo "[+] Creating backup: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
cp -a backend "${BACKUP_DIR}/backend"
cp -a agent "${BACKUP_DIR}/agent"

echo "[+] Patching backend imports/helpers/routes"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/main.py")
txt = p.read_text()

def ensure_import(module_line):
    global txt
    if module_line not in txt:
        lines = txt.splitlines()
        insert_at = 0
        while insert_at < len(lines) and (lines[insert_at].startswith("import ") or lines[insert_at].startswith("from ")):
            insert_at += 1
        lines.insert(insert_at, module_line)
        txt = "\n".join(lines) + "\n"

ensure_import("import hashlib")
ensure_import("import re")

# Add self_update to ALLOWED_ACTIONS regardless of order
m = re.search(r'ALLOWED_ACTIONS\s*=\s*\{([^}]+)\}', txt)
if not m:
    raise SystemExit("Could not find ALLOWED_ACTIONS")
items = {x.strip().strip('"').strip("'") for x in m.group(1).split(",") if x.strip()}
items.add("self_update")
new_allowed = 'ALLOWED_ACTIONS = {' + ", ".join(f'"{x}"' for x in sorted(items)) + '}'
txt = txt[:m.start()] + new_allowed + txt[m.end():]

if "def latest_agent_info():" not in txt:
    helper = r'''
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

'''
    # Put helpers before get_agent if present, otherwise before migrate_db
    marker = "def get_agent("
    if marker not in txt:
        marker = "def migrate_db("
    if marker not in txt:
        raise SystemExit("Could not find insertion marker for helper functions")
    txt = txt.replace(marker, helper + marker, 1)

if '@app.get("/api/v1/agent/latest"' not in txt:
    route = '''
@app.get("/api/v1/agent/latest")
def agent_latest():
    return latest_agent_info()

'''
    marker = '@app.get("/agent/patchpilot-agent.py"'
    idx = txt.find(marker)
    if idx == -1:
        # Append route if installer route marker is missing
        txt += "\n" + route
    else:
        txt = txt[:idx] + route + txt[idx:]

p.write_text(txt)
PY

echo "[+] Rewriting checkin function safely"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/main.py")
txt = p.read_text()

start = txt.find('@app.post("/api/v1/agent/checkin")')
if start == -1:
    raise SystemExit("Could not find checkin route")

# Find next route decorator after checkin
next_match = re.search(r'\n@app\.', txt[start + 1:])
if not next_match:
    raise SystemExit("Could not find end of checkin route")
end = start + 1 + next_match.start()

new_func = r'''@app.post("/api/v1/agent/checkin")
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

'''
txt = txt[:start] + new_func + txt[end+1:]
p.write_text(txt)
PY

echo "[+] Patching admin UI"

python3 - <<'PY'
from pathlib import Path

p = Path("backend/app/templates/admin.html")
txt = p.read_text()

if '<option value="self_update">update agent</option>' not in txt:
    txt = txt.replace(
        '<option value="apt_clean">apt clean</option>',
        '<option value="apt_clean">apt clean</option>\n            <option value="self_update">update agent</option>'
    )

p.write_text(txt)
PY

echo "[+] Patching agent"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("agent/patchpilot-agent.py")
txt = p.read_text()

txt = re.sub(r'AGENT_VERSION\s*=\s*"[^"]+"', 'AGENT_VERSION = "0.4.0"', txt)

if "import hashlib" not in txt:
    txt = txt.replace("import argparse\n", "import argparse\nimport hashlib\n")
if "import tempfile" not in txt:
    txt = txt.replace("import subprocess\n", "import subprocess\nimport tempfile\n")

m = re.search(r'ALLOWED_ACTIONS\s*=\s*\{([^}]+)\}', txt)
if not m:
    raise SystemExit("Could not find ALLOWED_ACTIONS in agent")
items = {x.strip().strip('"').strip("'") for x in m.group(1).split(",") if x.strip()}
items.add("self_update")
new_allowed = 'ALLOWED_ACTIONS = {' + ", ".join(f'"{x}"' for x in sorted(items)) + '}'
txt = txt[:m.start()] + new_allowed + txt[m.end():]

if "def self_update_agent(" not in txt:
    marker = "def execute_job(job):"
    helper = r'''
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
            if current_path.exists():
                backup_path.write_bytes(current_path.read_bytes())
                os.chmod(backup_path, 0o755)
        except Exception:
            pass

        tmp_path.replace(current_path)
        os.chmod(current_path, 0o755)

        return 0, f"Agent updated successfully. old_version={AGENT_VERSION} sha256={got_sha256}"

    except Exception as e:
        return 1, f"Agent self-update failed: {e}"

'''
    if marker not in txt:
        raise SystemExit("Could not find execute_job marker in agent")
    txt = txt.replace(marker, helper + marker, 1)

if 'if action == "self_update":' not in txt:
    marker = '''    if action == "apt_clean":
        return run("apt-get autoremove -y && apt-get autoclean -y", timeout=1800)

    return 1, "Unhandled action"
'''
    repl = '''    if action == "apt_clean":
        return run("apt-get autoremove -y && apt-get autoclean -y", timeout=1800)

    if action == "self_update":
        return self_update_agent(job.get("update_url"), job.get("sha256"))

    return 1, "Unhandled action"
'''
    if marker not in txt:
        raise SystemExit("Could not find apt_clean block in execute_job")
    txt = txt.replace(marker, repl, 1)

old = '''        for job in resp.get("jobs", []):
            job_id = job["id"]
            http_json("POST", f"{server}/api/v1/agent/jobs/{job_id}/started", {}, auth_headers(cfg))
            exit_code, output = execute_job(job)
            http_json(
                "POST",
                f"{server}/api/v1/agent/jobs/{job_id}/result",
                {"exit_code": exit_code, "output": output},
                auth_headers(cfg),
            )
'''
new = '''        update_info = resp.get("agent_update") or {}
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
'''
if old in txt:
    txt = txt.replace(old, new, 1)
elif "auto_agent_update" in txt:
    print("[+] Agent job loop already appears patched")
else:
    raise SystemExit("Could not safely patch agent job loop")

p.write_text(txt)
PY

chmod +x agent/patchpilot-agent.py
mkdir -p backend/app/static
cp agent/patchpilot-agent.py backend/app/static/patchpilot-agent.py
chmod 644 backend/app/static/patchpilot-agent.py

echo "[+] Updating .env.example"
if ! grep -q "PATCHPILOT_AUTO_AGENT_UPDATE" .env.example 2>/dev/null; then
  cat >> .env.example <<'EOF'

# If true, agents self-update automatically when backend serves a newer agent.
# Safer default is false. Manual update is available from MGMT UI via action self_update.
PATCHPILOT_AUTO_AGENT_UPDATE=false
EOF
fi

echo
echo "[+] Agent self-update v2 patch complete."
echo
echo "Backup saved in: ${BACKUP_DIR}"
echo
echo "Next:"
echo "  docker compose up -d --build"
echo
echo "First-time upgrade existing clients manually once:"
echo "  sudo curl -fsSL https://patch.labnat.xyz/agent/patchpilot-agent.py -o /usr/local/bin/patchpilot-agent"
echo "  sudo chmod 755 /usr/local/bin/patchpilot-agent"
echo "  sudo systemctl start patchpilot-agent.service"
