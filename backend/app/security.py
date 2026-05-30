# Copyright (C) 2026 Jonas Byström <jonas@lediga.st>
# SPDX-License-Identifier: GPL-3.0-or-later

import hashlib
import hmac
import os
import secrets
import time

from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def new_token(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(32)}"


def hash_token(token: str) -> str:
    return pwd_context.hash(token)


def verify_token(token: str, token_hash: str) -> bool:
    return pwd_context.verify(token, token_hash)


def make_csrf_token() -> str:
    secret = os.getenv("APP_SECRET", "change-me")
    hour = str(int(time.time()) // 3600)
    return hmac.new(secret.encode(), hour.encode(), hashlib.sha256).hexdigest()[:32]


def verify_csrf_token(token: str) -> bool:
    if not token:
        return False
    secret = os.getenv("APP_SECRET", "change-me")
    for offset in (0, 1):
        hour = str(int(time.time()) // 3600 - offset)
        expected = hmac.new(secret.encode(), hour.encode(), hashlib.sha256).hexdigest()[:32]
        if hmac.compare_digest(token, expected):
            return True
    return False
