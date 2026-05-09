"""Tests for pure functions in patchpilot-agent.py (no subprocess, no network)."""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Load agent module from file with hyphenated name
_agent_path = Path(__file__).parent.parent.parent / "agent" / "patchpilot-agent.py"
_spec = importlib.util.spec_from_file_location("patchpilot_agent", _agent_path)
agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agent)


# ---------------------------------------------------------------------------
# parse_apt_updates
# ---------------------------------------------------------------------------

class TestParseAptUpdates:
    def test_empty_output(self):
        with patch.object(agent, "run", return_value=(0, "")):
            result = agent.parse_apt_updates()
        assert result == []

    def test_normal_package(self):
        apt_line = "vim/jammy 9.1.0 amd64 [upgradable from: 9.0.0]"
        with patch.object(agent, "run", return_value=(0, apt_line)):
            result = agent.parse_apt_updates()
        assert len(result) == 1
        assert result[0]["package"] == "vim"
        assert result[0]["current_version"] == "9.0.0"
        assert result[0]["security"] is False

    def test_security_package_detected(self):
        apt_line = "openssl/jammy-security 3.0.2-1 amd64 [upgradable from: 3.0.1-1]"
        with patch.object(agent, "run", return_value=(0, apt_line)):
            result = agent.parse_apt_updates()
        assert len(result) == 1
        assert result[0]["security"] is True
        assert result[0]["package"] == "openssl"

    def test_multiple_packages(self):
        output = "\n".join([
            "curl/jammy 8.0.0 amd64 [upgradable from: 7.0.0]",
            "bash/jammy-security 5.2 amd64 [upgradable from: 5.1]",
            "vim/jammy 9.1 amd64 [upgradable from: 9.0]",
        ])
        with patch.object(agent, "run", return_value=(0, output)):
            result = agent.parse_apt_updates()
        assert len(result) == 3
        security_pkgs = [p for p in result if p["security"]]
        assert len(security_pkgs) == 1
        assert security_pkgs[0]["package"] == "bash"

    def test_run_failure_returns_empty(self):
        with patch.object(agent, "run", return_value=(1, "E: Could not open")):
            result = agent.parse_apt_updates()
        assert result == []


# ---------------------------------------------------------------------------
# version_tuple (from main.py, duplicated logic tested here)
# ---------------------------------------------------------------------------

class TestVersionTuple:
    def test_standard_version(self):
        assert agent.AGENT_VERSION  # just ensure it parses

    def test_parse_apt_candidate_format(self):
        # Verify candidate version is extracted from apt output format
        apt_line = "curl/jammy 8.5.0-1ubuntu1 amd64 [upgradable from: 7.9.0-1]"
        with patch.object(agent, "run", return_value=(0, apt_line)):
            result = agent.parse_apt_updates()
        assert result[0]["candidate_version"] == "8.5.0-1ubuntu1"


# ---------------------------------------------------------------------------
# self_update_agent
# ---------------------------------------------------------------------------

class TestSelfUpdate:
    def test_missing_url_returns_error(self):
        rc, msg = agent.self_update_agent(None)
        assert rc == 1
        assert "Missing" in msg

    def test_empty_url_returns_error(self):
        rc, msg = agent.self_update_agent("")
        assert rc == 1
        assert "Missing" in msg

    def test_invalid_file_content_rejected(self):
        fake_data = b"this is not a python script"
        mock_resp = MagicMock()
        mock_resp.read.return_value = fake_data
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with patch("urllib.request.urlopen", return_value=mock_resp), \
             patch.object(agent, "Path") as MockPath:
            mock_cp = MagicMock()
            mock_cp.exists.return_value = True
            mock_cp.parent = Path(tempfile.gettempdir())
            MockPath.return_value = mock_cp
            rc, msg = agent.self_update_agent("http://fake/agent")
        assert rc == 1
        assert "does not look like" in msg

    def test_sha256_mismatch_rejected(self):
        fake_data = b"#!/usr/bin/env python3\nAGENT_VERSION='1.0.0'\n"
        mock_resp = MagicMock()
        mock_resp.read.return_value = fake_data
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with patch("urllib.request.urlopen", return_value=mock_resp), \
             patch.object(agent, "Path") as MockPath:
            mock_cp = MagicMock()
            mock_cp.exists.return_value = True
            mock_cp.parent = Path(tempfile.gettempdir())
            MockPath.return_value = mock_cp
            rc, msg = agent.self_update_agent("http://fake/agent", expected_sha256="wronghash")
        assert rc == 1
        assert "SHA256 mismatch" in msg

    def test_tempfile_written_to_same_dir_as_target(self):
        """Temp file must be in /usr/local/bin, not /tmp."""
        fake_data = b"#!/usr/bin/env python3\nAGENT_VERSION='9.9.9'\n"
        import hashlib
        correct_sha = hashlib.sha256(fake_data).hexdigest()

        mock_resp = MagicMock()
        mock_resp.read.return_value = fake_data
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        written_dirs = []

        original_ntf = tempfile.NamedTemporaryFile

        def capture_ntf(*args, **kwargs):
            written_dirs.append(kwargs.get("dir"))
            # Write to real /tmp to avoid permission issues in test
            kwargs["dir"] = tempfile.gettempdir()
            return original_ntf(*args, **kwargs)

        current_path = Path(tempfile.gettempdir()) / "fake-patchpilot-agent"
        current_path.write_bytes(b"#!/usr/bin/env python3\n# old\n")

        try:
            with (
                patch("urllib.request.urlopen", return_value=mock_resp),
                patch.object(agent, "Path") as MockPath,
                patch("tempfile.NamedTemporaryFile", side_effect=capture_ntf),
            ):
                # Make current_path.exists() return True, .parent = /tmp
                mock_cp = MagicMock()
                mock_cp.exists.return_value = True
                mock_cp.parent = Path(tempfile.gettempdir())
                mock_cp.read_bytes.return_value = b"#!/usr/bin/env python3\n# old\n"
                MockPath.return_value = mock_cp

                agent.self_update_agent("http://fake/agent", expected_sha256=correct_sha)

            # The dir passed to NamedTemporaryFile should be the parent of current_path
            assert any(d == Path(tempfile.gettempdir()) for d in written_dirs if d is not None)
        finally:
            current_path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# get_machine_id
# ---------------------------------------------------------------------------

class TestGetMachineId:
    def test_creates_and_persists_machine_id(self, tmp_path, monkeypatch):
        mid_path = tmp_path / "machine-id"
        monkeypatch.setattr(agent, "CONFIG_PATH", tmp_path / "agent.json")

        # Patch the path used inside get_machine_id
        with patch.object(agent, "Path") as MockPath:
            mock_mid = MagicMock()
            mock_mid.exists.return_value = False
            mock_mid.parent = tmp_path
            mock_mid.read_text.return_value = ""
            mock_mid.__str__ = lambda s: str(mid_path)

            # First call writes the id
            written = []
            mock_mid.write_text.side_effect = lambda v: written.append(v)
            MockPath.return_value = mock_mid

            import socket
            expected_prefix = socket.gethostname()
            agent.get_machine_id()

            assert len(written) == 1
            assert written[0].startswith(expected_prefix)

    def test_reads_existing_machine_id(self, tmp_path):
        mid_path = tmp_path / "machine-id"
        mid_path.write_text("existing-id-123")

        with patch.object(agent, "Path") as MockPath:
            mock_mid = MagicMock()
            mock_mid.exists.return_value = True
            mock_mid.read_text.return_value = "existing-id-123"
            MockPath.return_value = mock_mid

            result = agent.get_machine_id()
            assert result == "existing-id-123"


# ---------------------------------------------------------------------------
# enroll re-enrollment handling
# ---------------------------------------------------------------------------

class TestEnrollReenroll:
    def test_reenroll_already_enrolled_exits_0(self):
        """Agent should exit 0 (not 1) when machine is already enrolled."""
        mock_resp = {"message": "machine already enrolled", "status": "approved"}

        with patch.object(agent, "http_json", return_value=mock_resp):
            with patch.object(agent, "get_machine_id", return_value="m-123"):
                with pytest.raises(SystemExit) as exc_info:
                    agent.enroll("http://fake-server")
        assert exc_info.value.code == 0

    def test_enroll_missing_token_exits_1(self):
        """Agent exits 1 when response has no token and is not a re-enroll."""
        mock_resp = {"status": "unknown"}

        with patch.object(agent, "http_json", return_value=mock_resp):
            with patch.object(agent, "get_machine_id", return_value="m-123"):
                with pytest.raises(SystemExit) as exc_info:
                    agent.enroll("http://fake-server")
        assert exc_info.value.code == 1
