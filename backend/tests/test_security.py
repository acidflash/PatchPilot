"""Tests for security.py: tokens, hashing, CSRF."""
import time

from app.security import (
    hash_token,
    make_csrf_token,
    new_token,
    verify_csrf_token,
    verify_token,
)


class TestTokens:
    def test_new_token_includes_prefix(self):
        t = new_token("pp_agent")
        assert t.startswith("pp_agent_")

    def test_new_token_is_unique(self):
        tokens = {new_token("pp_agent") for _ in range(50)}
        assert len(tokens) == 50

    def test_hash_and_verify_roundtrip(self):
        token = new_token("pp_agent")
        hashed = hash_token(token)
        assert verify_token(token, hashed)

    def test_wrong_token_fails_verification(self):
        token = new_token("pp_agent")
        hashed = hash_token(token)
        assert not verify_token("wrong-token", hashed)

    def test_empty_token_fails_verification(self):
        hashed = hash_token(new_token("pp_agent"))
        assert not verify_token("", hashed)


class TestCsrf:
    def test_make_csrf_token_returns_32_char_hex(self):
        token = make_csrf_token()
        assert len(token) == 32
        assert all(c in "0123456789abcdef" for c in token)

    def test_valid_token_passes_verification(self):
        token = make_csrf_token()
        assert verify_csrf_token(token)

    def test_wrong_token_fails(self):
        assert not verify_csrf_token("0" * 32)

    def test_empty_token_fails(self):
        assert not verify_csrf_token("")

    def test_token_is_deterministic_within_same_hour(self):
        t1 = make_csrf_token()
        t2 = make_csrf_token()
        assert t1 == t2

    def test_previous_hour_token_still_valid(self, monkeypatch):
        """Tokens from the previous hour should still be accepted."""
        # Generate a token as if it's one hour earlier
        import hmac
        import hashlib
        import os
        secret = os.environ["APP_SECRET"]
        prev_hour = str(int(time.time()) // 3600 - 1)
        old_token = hmac.new(secret.encode(), prev_hour.encode(), hashlib.sha256).hexdigest()[:32]
        assert verify_csrf_token(old_token)

    def test_two_hour_old_token_rejected(self):
        import hmac
        import hashlib
        import os
        secret = os.environ["APP_SECRET"]
        old_hour = str(int(time.time()) // 3600 - 2)
        stale_token = hmac.new(secret.encode(), old_hour.encode(), hashlib.sha256).hexdigest()[:32]
        assert not verify_csrf_token(stale_token)
