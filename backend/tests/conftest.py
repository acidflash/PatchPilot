import os

# Must be set before any app imports so db.py and security.py pick them up
os.environ.setdefault("DATABASE_URL", "sqlite:///./test_patchpilot.db")
os.environ.setdefault("APP_SECRET", "test-secret-for-testing-only-32chars!")
os.environ.setdefault("ADMIN_PASSWORD", "")
os.environ.setdefault("PATCHPILOT_AUTO_APPROVE_AGENTS", "true")
os.environ.setdefault("PUBLIC_AGENT_URL", "http://testserver")
os.environ.setdefault("AGENT_PUBLIC_HOSTNAME", "agent.test")
os.environ.setdefault("ADMIN_INTERNAL_HOSTNAMES", "admin.test")
os.environ.setdefault("DISCORD_WEBHOOK_URL", "")

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.db import Base, get_db
from app.main import app, _enroll_timestamps

_TEST_DB = os.environ["DATABASE_URL"]
_engine = create_engine(_TEST_DB, connect_args={"check_same_thread": False})
_Session = sessionmaker(autocommit=False, autoflush=False, bind=_engine)


@pytest.fixture(scope="session", autouse=True)
def _create_tables():
    Base.metadata.create_all(bind=_engine)
    yield
    Base.metadata.drop_all(bind=_engine)
    try:
        os.remove("test_patchpilot.db")
    except FileNotFoundError:
        pass


@pytest.fixture(autouse=True)
def _clean_state(_create_tables):
    yield
    with _engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            conn.execute(table.delete())
    _enroll_timestamps.clear()


def _override_db():
    db = _Session()
    try:
        yield db
    finally:
        db.close()


@pytest.fixture
def client():
    app.dependency_overrides[get_db] = _override_db
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def csrf():
    from app.security import make_csrf_token
    return make_csrf_token()


@pytest.fixture
def enrolled(client):
    """Enroll a machine and return (machine_db_id, agent_token, machine_id)."""
    resp = client.post("/api/v1/agent/enroll", json={
        "machine_id": "test-machine-001",
        "hostname": "testhost",
        "agent_version": "0.5.0",
        "os_version": "Ubuntu 22.04",
        "kernel_version": "5.15.0",
    })
    assert resp.status_code == 200
    data = resp.json()
    token = data["agent_token"]

    db = _Session()
    from app.models import Machine
    m = db.query(Machine).filter(Machine.machine_id == "test-machine-001").first()
    db_id = m.id
    db.close()

    return db_id, token, "test-machine-001"
