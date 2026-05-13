"""Integration tests for FastAPI endpoints."""
import pytest
from app.security import make_csrf_token
from app.models import Job, Machine, Schedule


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def agent_headers(token: str, machine_id: str) -> dict:
    return {
        "X-Agent-ID": machine_id,
        "Authorization": f"Bearer {token}",
    }


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

class TestHealth:
    def test_healthz(self, client):
        resp = client.get("/healthz")
        assert resp.status_code == 200
        assert resp.text == "ok"


# ---------------------------------------------------------------------------
# Enrollment
# ---------------------------------------------------------------------------

class TestEnroll:
    def test_enroll_new_machine(self, client):
        resp = client.post("/api/v1/agent/enroll", json={
            "machine_id": "m-001",
            "hostname": "host-1",
            "agent_version": "0.5.0",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["machine_id"] == "m-001"
        assert "agent_token" in data
        assert data["agent_token"].startswith("pp_agent_")
        assert data["approved"] is True  # auto-approve enabled in conftest

    def test_enroll_missing_machine_id(self, client):
        resp = client.post("/api/v1/agent/enroll", json={"hostname": "host"})
        assert resp.status_code == 400

    def test_enroll_missing_hostname(self, client):
        resp = client.post("/api/v1/agent/enroll", json={"machine_id": "m-001"})
        assert resp.status_code == 400

    def test_reenroll_already_enrolled_returns_no_token(self, client):
        payload = {"machine_id": "m-dup", "hostname": "host"}
        client.post("/api/v1/agent/enroll", json=payload)
        resp = client.post("/api/v1/agent/enroll", json=payload)
        assert resp.status_code == 200
        data = resp.json()
        assert data["message"] == "machine already enrolled"
        assert "agent_token" not in data

    def test_enroll_rate_limit(self, client):
        import time
        from app.main import _enroll_timestamps, _ENROLL_RATE_MAX
        # Fill up the rate limit bucket for testclient IP with current timestamps
        _enroll_timestamps["testclient"] = [time.time()] * _ENROLL_RATE_MAX
        resp = client.post("/api/v1/agent/enroll", json={
            "machine_id": "m-rate", "hostname": "h"
        })
        assert resp.status_code == 429


# ---------------------------------------------------------------------------
# Checkin
# ---------------------------------------------------------------------------

class TestCheckin:
    def test_checkin_requires_auth(self, client):
        resp = client.post("/api/v1/agent/checkin", json={})
        assert resp.status_code == 401

    def test_checkin_wrong_token(self, client, enrolled):
        db_id, _, machine_id = enrolled
        resp = client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost"},
            headers={"X-Agent-ID": machine_id, "Authorization": "Bearer wrong"},
        )
        assert resp.status_code == 401

    def test_checkin_valid_agent(self, client, enrolled):
        db_id, token, machine_id = enrolled
        resp = client.post(
            "/api/v1/agent/checkin",
            json={
                "hostname": "testhost",
                "os_version": "Ubuntu 22.04",
                "kernel_version": "5.15.0",
                "agent_version": "0.5.0",
                "updates_available": 3,
                "security_updates_available": 1,
                "reboot_required": False,
            },
            headers=agent_headers(token, machine_id),
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["approved"] is True
        assert "jobs" in data
        assert "agent_update" in data
        assert "policy" in data

    def test_checkin_with_packages(self, client, enrolled):
        db_id, token, machine_id = enrolled
        resp = client.post(
            "/api/v1/agent/checkin",
            json={
                "hostname": "testhost",
                "packages": [
                    {"package": "curl", "current_version": "7.0", "candidate_version": "8.0", "security": True},
                    {"package": "vim", "current_version": "9.0", "candidate_version": "9.1", "security": False},
                ],
            },
            headers=agent_headers(token, machine_id),
        )
        assert resp.status_code == 200

    def test_checkin_truncates_large_package_list(self, client, enrolled):
        db_id, token, machine_id = enrolled
        packages = [{"package": f"pkg-{i}", "security": False} for i in range(600)]
        resp = client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "packages": packages},
            headers=agent_headers(token, machine_id),
        )
        assert resp.status_code == 200

    def test_auto_patch_creates_job_when_updates_available(self, client, enrolled):
        from tests.conftest import _Session
        db_id, token, machine_id = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.auto_patch = True
        machine.auto_reboot = False
        db.commit()
        db.close()

        resp = client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "updates_available": 5, "security_updates_available": 1},
            headers=agent_headers(token, machine_id),
        )
        assert resp.status_code == 200
        data = resp.json()
        assert any(j["action"] == "upgrade" for j in data["jobs"])

        db = _Session()
        job = db.query(Job).filter(Job.machine_id == db_id, Job.created_by == "auto_patch").first()
        assert job is not None
        assert job.allow_reboot is False
        db.close()

    def test_auto_patch_respects_auto_reboot(self, client, enrolled):
        from tests.conftest import _Session
        db_id, token, machine_id = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.auto_patch = True
        machine.auto_reboot = True
        db.commit()
        db.close()

        client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "updates_available": 3},
            headers=agent_headers(token, machine_id),
        )

        db = _Session()
        job = db.query(Job).filter(Job.machine_id == db_id, Job.created_by == "auto_patch").first()
        assert job is not None
        assert job.allow_reboot is True
        db.close()

    def test_auto_patch_skipped_when_no_updates(self, client, enrolled):
        from tests.conftest import _Session
        db_id, token, machine_id = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.auto_patch = True
        db.commit()
        db.close()

        client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "updates_available": 0},
            headers=agent_headers(token, machine_id),
        )

        db = _Session()
        job = db.query(Job).filter(Job.machine_id == db_id, Job.created_by == "auto_patch").first()
        assert job is None
        db.close()

    def test_auto_patch_skipped_when_disabled(self, client, enrolled):
        from tests.conftest import _Session
        db_id, token, machine_id = enrolled

        client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "updates_available": 10},
            headers=agent_headers(token, machine_id),
        )

        db = _Session()
        job = db.query(Job).filter(Job.machine_id == db_id, Job.created_by == "auto_patch").first()
        assert job is None
        db.close()

    def test_auto_patch_no_duplicate_when_job_already_pending(self, client, enrolled):
        from tests.conftest import _Session
        db_id, token, machine_id = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.auto_patch = True
        db.add(Job(machine_id=db_id, action="upgrade", status="pending", created_by="manual"))
        db.commit()
        db.close()

        client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost", "updates_available": 5},
            headers=agent_headers(token, machine_id),
        )

        db = _Session()
        count = db.query(Job).filter(Job.machine_id == db_id).count()
        assert count == 1  # no second job created
        db.close()


# ---------------------------------------------------------------------------
# Job lifecycle
# ---------------------------------------------------------------------------

class TestJobs:
    def _create_job(self, client, machine_pk, csrf, action="check_updates"):
        resp = client.post(
            f"/admin/machines/{machine_pk}/jobs",
            data={"action": action, "csrf_token": csrf},
        )
        assert resp.status_code == 303
        from app.models import Job
        from app.db import get_db
        db = next(_override_db_for_query())
        job = db.query(Job).filter(Job.machine_id == machine_pk).first()
        db.close()
        return job.id

    def test_job_started_and_result(self, client, enrolled, csrf):
        db_id, token, machine_id = enrolled
        headers = agent_headers(token, machine_id)

        # Create job via admin
        client.post(
            f"/admin/machines/{db_id}/jobs",
            data={"action": "check_updates", "csrf_token": csrf},
        )

        # Fetch job via checkin
        resp = client.post(
            "/api/v1/agent/checkin",
            json={"hostname": "testhost"},
            headers=headers,
        )
        jobs = resp.json()["jobs"]
        assert len(jobs) == 1
        job_id = jobs[0]["id"]

        # Mark started
        resp = client.post(f"/api/v1/agent/jobs/{job_id}/started", headers=headers)
        assert resp.status_code == 200

        # Submit result
        resp = client.post(
            f"/api/v1/agent/jobs/{job_id}/result",
            json={"exit_code": 0, "output": "All good"},
            headers=headers,
        )
        assert resp.status_code == 200

    def test_wrong_agent_cannot_access_job(self, client, csrf):
        # Enroll two agents
        client.post("/api/v1/agent/enroll", json={"machine_id": "m-a", "hostname": "a"})
        r2 = client.post("/api/v1/agent/enroll", json={"machine_id": "m-b", "hostname": "b"})
        token_b = r2.json()["agent_token"]

        from app.models import Machine, Job
        from sqlalchemy.orm import sessionmaker
        from sqlalchemy import create_engine
        import os
        eng = create_engine(os.environ["DATABASE_URL"], connect_args={"check_same_thread": False})
        Sess = sessionmaker(bind=eng)
        db = Sess()
        m_a = db.query(Machine).filter(Machine.machine_id == "m-a").first()
        db.add(Job(machine_id=m_a.id, action="check_updates", status="pending"))
        db.commit()
        job = db.query(Job).filter(Job.machine_id == m_a.id).first()
        job_id = job.id
        db.close()

        # Agent B tries to access Agent A's job
        resp = client.post(
            f"/api/v1/agent/jobs/{job_id}/started",
            headers={"X-Agent-ID": "m-b", "Authorization": f"Bearer {token_b}"},
        )
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# CSRF protection
# ---------------------------------------------------------------------------

class TestCsrf:
    def test_admin_post_without_csrf_returns_403(self, client, enrolled):
        db_id, _, _ = enrolled
        resp = client.post(
            f"/admin/machines/{db_id}/jobs",
            data={"action": "check_updates"},
        )
        assert resp.status_code == 403

    def test_admin_post_with_wrong_csrf_returns_403(self, client, enrolled):
        db_id, _, _ = enrolled
        resp = client.post(
            f"/admin/machines/{db_id}/jobs",
            data={"action": "check_updates", "csrf_token": "0" * 32},
        )
        assert resp.status_code == 403

    def test_admin_post_with_valid_csrf_succeeds(self, client, enrolled, csrf):
        db_id, _, _ = enrolled
        resp = client.post(
            f"/admin/machines/{db_id}/jobs",
            data={"action": "check_updates", "csrf_token": csrf},
            follow_redirects=False,
        )
        assert resp.status_code == 303

    def test_all_admin_post_routes_require_csrf(self, client, enrolled, csrf):
        db_id, _, _ = enrolled
        routes_without_csrf = [
            (f"/admin/machines/{db_id}/enable", {}),
            (f"/admin/machines/{db_id}/disable", {}),
            (f"/admin/machines/{db_id}/delete", {}),
            (f"/admin/machines/{db_id}/delete-jobs", {}),
            (f"/admin/machines/{db_id}/approve", {}),
            (f"/admin/machines/{db_id}/reject", {}),
        ]
        for url, data in routes_without_csrf:
            resp = client.post(url, data=data)
            assert resp.status_code == 403, f"Expected 403 for {url}, got {resp.status_code}"


# ---------------------------------------------------------------------------
# Admin authentication
# ---------------------------------------------------------------------------

class TestAdminAuth:
    def test_admin_requires_password_when_set(self, client, monkeypatch):
        monkeypatch.setenv("ADMIN_PASSWORD", "secret123")
        resp = client.get("/admin")
        assert resp.status_code == 401
        assert "WWW-Authenticate" in resp.headers

    def test_admin_allows_correct_password(self, client, monkeypatch):
        monkeypatch.setenv("ADMIN_PASSWORD", "secret123")
        resp = client.get("/admin", auth=("admin", "secret123"))
        assert resp.status_code == 200

    def test_admin_rejects_wrong_password(self, client, monkeypatch):
        monkeypatch.setenv("ADMIN_PASSWORD", "secret123")
        resp = client.get("/admin", auth=("admin", "wrong"))
        assert resp.status_code == 401

    def test_admin_accessible_without_password_by_default(self, client):
        # ADMIN_PASSWORD="" in conftest → no auth required
        resp = client.get("/admin")
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Host-based routing
# ---------------------------------------------------------------------------

class TestHostRouting:
    def test_agent_host_blocks_admin(self, client):
        resp = client.get("/admin", headers={"Host": "agent.test"})
        assert resp.status_code == 404

    def test_agent_host_allows_healthz(self, client):
        resp = client.get("/healthz", headers={"Host": "agent.test"})
        assert resp.status_code == 200

    def test_agent_host_allows_enroll(self, client):
        resp = client.post(
            "/api/v1/agent/enroll",
            json={"machine_id": "m-host", "hostname": "h"},
            headers={"Host": "agent.test"},
        )
        assert resp.status_code == 200

    def test_admin_host_blocks_agent_api(self, client):
        resp = client.post(
            "/api/v1/agent/enroll",
            json={"machine_id": "m-x", "hostname": "h"},
            headers={"Host": "admin.test"},
        )
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Admin endpoints
# ---------------------------------------------------------------------------

class TestAdminEndpoints:
    def test_admin_page_loads(self, client):
        resp = client.get("/admin")
        assert resp.status_code == 200
        assert "PatchPilot" in resp.text

    def test_admin_page_has_csrf_meta_tag(self, client):
        resp = client.get("/admin")
        assert 'meta name="csrf-token"' in resp.text

    def test_admin_page_uses_data_confirm_not_inline_js(self, client):
        resp = client.get("/admin")
        html = resp.text
        # XSS fix: template vars must NOT appear in JS confirm() calls
        assert "confirm('Reject agent" not in html
        assert "confirm('Delete agent" not in html
        assert "confirm('Delete job" not in html
        # Safe JS confirm handler must be present (data-confirm pattern)
        assert "data-confirm" in html or "dataset.confirm" in html

    def test_approve_machine(self, client, csrf):
        # Temporarily disable auto-approve to create pending machine
        import os
        old = os.environ.get("PATCHPILOT_AUTO_APPROVE_AGENTS")
        os.environ["PATCHPILOT_AUTO_APPROVE_AGENTS"] = "false"
        try:
            r = client.post("/api/v1/agent/enroll", json={"machine_id": "m-pend", "hostname": "h"})
            token = r.json()["agent_token"]
        finally:
            os.environ["PATCHPILOT_AUTO_APPROVE_AGENTS"] = old or "true"

        from app.models import Machine
        from sqlalchemy.orm import sessionmaker
        from sqlalchemy import create_engine
        eng = create_engine(os.environ["DATABASE_URL"], connect_args={"check_same_thread": False})
        db = sessionmaker(bind=eng)()
        m = db.query(Machine).filter(Machine.machine_id == "m-pend").first()
        assert m.approved is False
        db_id = m.id
        db.close()

        resp = client.post(f"/admin/machines/{db_id}/approve", data={"csrf_token": csrf}, follow_redirects=False)
        assert resp.status_code == 303

        db = sessionmaker(bind=eng)()
        m = db.query(Machine).filter(Machine.machine_id == "m-pend").first()
        assert m.approved is True
        db.close()

    def test_create_group(self, client, csrf):
        resp = client.post(
            "/admin/groups",
            data={"name": "prod-servers", "description": "Production", "csrf_token": csrf},
            follow_redirects=False,
        )
        assert resp.status_code == 303

    def test_create_group_duplicate_returns_409(self, client, csrf):
        data = {"name": "my-group", "description": "", "csrf_token": csrf}
        client.post("/admin/groups", data=data)
        resp = client.post("/admin/groups", data=data)
        assert resp.status_code == 409

    def test_create_schedule_invalid_time_format(self, client, enrolled, csrf):
        db_id, _, _ = enrolled
        resp = client.post("/admin/schedules", data={
            "name": "sched",
            "target_type": "machine",
            "target_id": db_id,
            "action": "upgrade",
            "time_of_day": "3:00",  # invalid — not HH:MM
            "csrf_token": csrf,
        })
        assert resp.status_code == 400

    def test_create_schedule_valid(self, client, enrolled, csrf):
        db_id, _, _ = enrolled
        resp = client.post("/admin/schedules", data={
            "name": "nightly",
            "target_type": "machine",
            "target_id": db_id,
            "action": "upgrade",
            "time_of_day": "03:00",
            "csrf_token": csrf,
        }, follow_redirects=False)
        assert resp.status_code == 303

    def test_delete_machine_jobs_nonexistent_machine(self, client, csrf):
        resp = client.post(
            "/admin/machines/99999/delete-jobs",
            data={"csrf_token": csrf},
        )
        assert resp.status_code == 404

    def test_invalid_action_rejected(self, client, enrolled, csrf):
        db_id, _, _ = enrolled
        resp = client.post(
            f"/admin/machines/{db_id}/jobs",
            data={"action": "rm -rf /", "csrf_token": csrf},
        )
        assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Agent latest
# ---------------------------------------------------------------------------

class TestAgentLatest:
    def test_agent_latest_returns_json(self, client):
        resp = client.get("/api/v1/agent/latest")
        assert resp.status_code == 200
        data = resp.json()
        assert "version" in data
        assert "sha256" in data
        assert "url" in data


# ---------------------------------------------------------------------------
# Schedule job filtering (only create patch jobs when updates exist)
# ---------------------------------------------------------------------------

class TestRunSchedules:
    def _make_schedule(self, db, machine, action="upgrade", allow_reboot=False):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        now = datetime.now(ZoneInfo("UTC"))
        s = Schedule(
            name="test-sched",
            target_type="machine",
            target_id=machine.id,
            action=action,
            day_of_week="all",
            time_of_day=now.strftime("%H:%M"),
            timezone="UTC",
            allow_reboot=allow_reboot,
            require_approval=False,
            enabled=True,
        )
        db.add(s)
        db.commit()
        return s

    def test_upgrade_skipped_when_no_updates(self, client, enrolled):
        from tests.conftest import _Session
        db_id, _, _ = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.updates_available = 0
        db.commit()

        self._make_schedule(db, machine, action="upgrade")

        from app.main import run_schedules
        run_schedules()

        jobs = db.query(Job).filter(Job.machine_id == db_id).all()
        db.close()
        assert len(jobs) == 0

    def test_upgrade_created_when_updates_available(self, client, enrolled):
        from tests.conftest import _Session
        db_id, _, _ = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.updates_available = 5
        db.commit()

        self._make_schedule(db, machine, action="upgrade")

        from app.main import run_schedules
        run_schedules()

        jobs = db.query(Job).filter(Job.machine_id == db_id).all()
        db.close()
        assert len(jobs) == 1
        assert jobs[0].action == "upgrade"

    def test_security_upgrade_skipped_when_no_security_updates(self, client, enrolled):
        from tests.conftest import _Session
        db_id, _, _ = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.updates_available = 3
        machine.security_updates_available = 0
        db.commit()

        self._make_schedule(db, machine, action="security_upgrade")

        from app.main import run_schedules
        run_schedules()

        jobs = db.query(Job).filter(Job.machine_id == db_id).all()
        db.close()
        assert len(jobs) == 0

    def test_security_upgrade_created_when_security_updates_available(self, client, enrolled):
        from tests.conftest import _Session
        db_id, _, _ = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.security_updates_available = 2
        db.commit()

        self._make_schedule(db, machine, action="security_upgrade")

        from app.main import run_schedules
        run_schedules()

        jobs = db.query(Job).filter(Job.machine_id == db_id).all()
        db.close()
        assert len(jobs) == 1
        assert jobs[0].action == "security_upgrade"

    def test_allow_reboot_false_sets_job_allow_reboot_false(self, client, enrolled):
        from tests.conftest import _Session
        db_id, _, _ = enrolled
        db = _Session()
        machine = db.query(Machine).filter(Machine.id == db_id).first()
        machine.updates_available = 1
        db.commit()

        self._make_schedule(db, machine, action="upgrade", allow_reboot=False)

        from app.main import run_schedules
        run_schedules()

        job = db.query(Job).filter(Job.machine_id == db_id).first()
        db.close()
        assert job is not None
        assert job.allow_reboot is False
