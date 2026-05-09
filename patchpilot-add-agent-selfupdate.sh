#!/usr/bin/env bash
set -euo pipefail

# PatchPilot agent self-update upgrade
# Run from inside existing patchpilot project directory:
#   cd patchpilot
#   bash patchpilot-add-agent-selfupdate.sh
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
BACKUP_DIR="_backup_selfupdate_${TS}"

echo "[+] Creating backup: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
cp -a backend "${BACKUP_DIR}/backend"
cp -a agent "${BACKUP_DIR}/agent"

echo "[+] Patching backend"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/main.py")
txt = p.read_text()

if "import hashlib" not in txt:
    txt = txt.replace("import json\n", "import json\nimport hashlib\n")

if "import re" not in txt:
    txt = txt.replace("import os\n", "import os\nimport re\n")

txt = txt.replace(
    'ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean"}',
    'ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean", "self_update"}'
)

if "def latest_agent_info():" not in txt:
    marker = "def migrate_db():"
    helper = '''
def latest_agent_info():
    agent_path = "app/static/patchpilot-agent.py"
    try:
        with open(agent_path, "rb") as f:
            data = f.read()
        content = data.decode("utf-8", errors="replace")
        m = re.search(r'AGENT_VERSION\\s*=\\s*["\\']([^"\\']+)["\\']', content)
        version = m.group(1) if m else "unknown"
        sha256 = hashlib.sha256(data).hexdigest()
        public_url = os.getenv("PUBLIC_AGENT_URL", "").rstrip("/")
        update_url = f"{public_url}/agent/patchpilot-agent.py" if public_url else "/agent/patchpilot-agent.py"
        return {"version": version, "sha256": sha256, "url": update_url}
    except Exception:
        return {"version": "unknown", "sha256": "", "url": "/agent/patchpilot-agent.py"}

def version_tuple(v: str):
    try:
        return tuple(int(x) for x in re.findall(r"\\d+", v)[:3])
    except Exception:
        return (0, 0, 0)

def agent_is_outdated(current: str | None, latest: str | None) -> bool:
    if not current or not latest or latest == "unknown":
        return False
    return version_tuple(current) < version_tuple(latest)

'''
    if marker not in txt:
        raise SystemExit("Could not find migrate_db marker in backend/app/main.py")
    txt = txt.replace(marker, helper + marker)

if '@app.get("/api/v1/agent/latest"' not in txt:
    marker = '@app.get("/agent/patchpilot-agent.py", response_class=PlainTextResponse)'
    route = '''
@app.get("/api/v1/agent/latest")
def agent_latest():
    return latest_agent_info()

'''
    if marker not in txt:
        raise SystemExit("Could not find /agent/patchpilot-agent.py route marker")
    txt = txt.replace(marker, route + marker)

old = '''    return {
        "status": "ok",
        "policy": {
            "auto_patch": machine.auto_patch,
            "auto_reboot": machine.auto_reboot,
        },
        "jobs": [{"id": job.id, "action": job.action, "allow_reboot": job.allow_reboot} for job in jobs],
    }
'''
new = '''    latest = latest_agent_info()
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
if old in txt:
    txt = txt.replace(old, new)
elif '"agent_update":' in txt:
    print("[+] checkin response already has agent_update")
else:
    raise SystemExit("Could not safely patch checkin response. Manual patch needed.")

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
        '<option value="apt_clean">apt clean</option>\\n            <option value="self_update">update agent</option>'
    )

p.write_text(txt)
PY

echo "[+] Patching agent"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("agent/patchpilot-agent.py")
txt = p.read_text()

txt = re.sub(r'AGENT_VERSION\\s*=\\s*"[^"]+"', 'AGENT_VERSION = "0.4.0"', txt)

if "import hashlib" not in txt:
    txt = txt.replace("import argparse\n", "import argparse\nimport hashlib\n")
if "import tempfile" not in txt:
    txt = txt.replace("import subprocess\n", "import subprocess\nimport tempfile\n")

txt = txt.replace(
    'ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean"}',
    'ALLOWED_ACTIONS = {"check_updates", "upgrade", "security_upgrade", "reboot", "apt_clean", "self_update"}'
)

if "def self_update_agent(" not in txt:
    marker = "def execute_job(job):"
    helper = '''
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
    txt = txt.replace(marker, helper + marker)

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
    txt = txt.replace(marker, repl)

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
    txt = txt.replace(old, new)
elif "auto_agent_update" in txt:
    print("[+] Agent job loop already appears patched")
else:
    raise SystemExit("Could not safely patch agent job loop")

p.write_text(txt)
PY

chmod +x agent/patchpilot-agent.py
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
echo "[+] Agent self-update patch complete."
echo
echo "Backup saved in: ${BACKUP_DIR}"
echo
echo "Next:"
echo "  docker compose up -d --build"
echo
echo "Manual agent update from MGMT:"
echo "  choose action: update agent"
echo
echo "Optional automatic updates:"
echo "  set PATCHPILOT_AUTO_AGENT_UPDATE=true in .env"
echo "  docker compose up -d --build"
