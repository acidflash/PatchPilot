#!/usr/bin/env python3
# Copyright (C) 2026 Jonas Byström <jonas@lediga.st>
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from urllib import request, error

AGENT_VERSION = "0.7.1"
CONFIG_PATH = Path("/etc/patchpilot/agent.json")
BOOTSTRAP_PATH = Path("/etc/patchpilot/bootstrap.json")
CACHE_PATH = Path("/etc/patchpilot/status-cache.json")
ALLOWED_ACTIONS = {"apt_clean", "check_updates", "reboot", "security_upgrade", "self_update", "upgrade"}
CHECK_INTERVAL = 6 * 3600  # full apt-get update at most every 6 hours (≈4×/day)

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
            raw = resp.read().decode('utf-8', errors='replace')
            return json.loads(raw) if raw else {}
    except error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.read().decode('utf-8', errors='replace')}", file=sys.stderr)
        raise
    except error.URLError as e:
        print(f"Network error: {e.reason}", file=sys.stderr)
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

def get_skipped_packages():
    """Return (phased, held_back) sets — packages apt-get upgrade won't install."""
    rc, out = run("apt-get upgrade --simulate 2>&1 || true", timeout=120)
    phased = set()
    held_back = set()
    section = None
    for line in out.splitlines():
        low = line.lower()
        if "deferred due to phasing" in low:
            section = "phased"
            continue
        if "the following packages have been kept back" in low:
            section = "held_back"
            continue
        if section:
            stripped = line.strip()
            if not stripped or stripped.startswith("Reading") or stripped.startswith("The following"):
                section = None
                continue
            target = phased if section == "phased" else held_back
            for pkg in stripped.split():
                target.add(pkg)
    return phased, held_back

def parse_apt_updates():
    rc, out = run("apt list --upgradable 2>/dev/null | tail -n +2", timeout=180)
    packages = []
    if rc != 0:
        return packages

    phased, held_back = get_skipped_packages()

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
            "phased": pkg_name in phased,
            "held_back": pkg_name in held_back,
            "raw": line,
        })

    return packages

def apt_check_counts(packages):
    installable = [p for p in packages if not p.get("phased") and not p.get("held_back")]
    updates = len(installable)
    security = len([p for p in installable if p.get("security")])

    checker = Path("/usr/lib/update-notifier/apt-check")
    if checker.exists():
        rc, out = run("/usr/lib/update-notifier/apt-check 2>/dev/null || true", timeout=120)
        m = re.search(r"(\d+)\s*;\s*(\d+)", out)
        if m:
            # apt-check doesn't account for phasing or held-back — subtract skipped counts
            skipped_total = len(packages) - len(installable)
            skipped_sec = len([p for p in packages if (p.get("phased") or p.get("held_back")) and p.get("security")])
            updates = max(0, int(m.group(1)) - skipped_total)
            security = max(0, int(m.group(2)) - skipped_sec)

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

    phased_count = len([p for p in packages if p.get("phased")])
    held_back_count = len([p for p in packages if p.get("held_back")])

    return {
        "hostname": socket.gethostname(),
        "os_version": get_os_version(),
        "kernel_version": platform.release(),
        "agent_version": AGENT_VERSION,
        "updates_available": updates,
        "security_updates_available": security,
        "phased_updates_available": phased_count,
        "held_back_updates_available": held_back_count,
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
        if resp.get("message") == "machine already enrolled":
            print(
                f"Machine already enrolled (status={resp.get('status')}). "
                "Use the existing /etc/patchpilot/agent.json or rotate the token via the admin dashboard.",
                file=sys.stderr,
            )
            sys.exit(0)
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
        if not expected_sha256:
            return 1, "Server did not provide a SHA256 checksum; refusing update"
        if expected_sha256 != got_sha256:
            return 1, f"SHA256 mismatch. expected={expected_sha256} got={got_sha256}"

        with tempfile.NamedTemporaryFile("wb", delete=False, dir=current_path.parent, prefix="patchpilot-agent-", suffix=".new") as tmp:
            tmp.write(data)
            tmp_path = Path(tmp.name)

        os.chmod(tmp_path, 0o755)

        backup_path = Path(f"/usr/local/bin/patchpilot-agent.bak-{AGENT_VERSION}")
        try:
            backup_path.write_bytes(current_path.read_bytes())
            os.chmod(backup_path, 0o755)
        except Exception:
            pass

        try:
            tmp_path.replace(current_path)
        except OSError:
            # Atomic rename fails across filesystems — fall back to copy+delete
            shutil.copy2(str(tmp_path), str(current_path))
            tmp_path.unlink(missing_ok=True)
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
        _save_status_cache(status)
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

def _load_status_cache():
    try:
        if CACHE_PATH.exists():
            return json.loads(CACHE_PATH.read_text())
    except Exception:
        pass
    return None


def _save_status_cache(status):
    try:
        data = dict(status)
        data["_checked_at"] = time.time()
        CACHE_PATH.write_text(json.dumps(data))
        os.chmod(CACHE_PATH, 0o600)
    except Exception:
        pass


def run_once():
    cfg = bootstrap_if_needed()
    server = cfg["server_url"].rstrip("/")

    now = time.time()
    cached = _load_status_cache()
    last_checked_at = cached.get("_checked_at", 0) if cached else 0
    do_full_check = not cached or (now - last_checked_at) >= CHECK_INTERVAL

    status = None
    try:
        if do_full_check:
            status = collect_status()
            _save_status_cache(status)
        else:
            status = {k: v for k, v in cached.items() if not k.startswith("_")}
            status["hostname"] = socket.gethostname()
            status["kernel_version"] = platform.release()
            status["agent_version"] = AGENT_VERSION
            status["reboot_required"] = Path("/var/run/reboot-required").exists()

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

            # Invalidate cache after patching so next run re-checks actual update status
            if exit_code == 0 and job.get("action") in ("upgrade", "security_upgrade"):
                try:
                    CACHE_PATH.unlink(missing_ok=True)
                except Exception:
                    pass

    except Exception as e:
        last_error = str(e)
        try:
            fallback = status if status is not None else {"hostname": socket.gethostname(), "agent_version": AGENT_VERSION}
            fallback["last_error"] = last_error
            http_json("POST", f"{server}/api/v1/agent/checkin", fallback, auth_headers(cfg))
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
