#!/usr/bin/env python3
import argparse, json, os, platform, re, socket, subprocess, sys, uuid
from pathlib import Path
from urllib import request, error
AGENT_VERSION = "0.4.0"
CONFIG_PATH = Path("/etc/patchpilot/agent.json")
ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}

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
    cfg = load_config()
    server = cfg["server_url"].rstrip("/")

    last_error = None

    try:
        status = collect_status()
        resp = http_json("POST", f"{server}/api/v1/agent/checkin", status, auth_headers(cfg))

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
    parser = argparse.ArgumentParser(); parser.add_argument("--enroll", action="store_true"); parser.add_argument("--server"); parser.add_argument("--once", action="store_true"); args = parser.parse_args()
    if args.enroll:
        if not args.server: print("--server is required with --enroll", file=sys.stderr); sys.exit(1)
        enroll(args.server)
    else: run_once()
