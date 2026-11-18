"""Narrow QStash HS256 verification using documented claims and standard HMAC."""

import base64
import binascii
import hashlib
import hmac
import json
import re
from datetime import datetime
from typing import Any

from pydantic import SecretStr

from aurora_backend.domain.types import utc

# Seconds a token may appear to come from the future, for clock drift between
# QStash and this server. Expiry is not extended.
CLOCK_LEEWAY = 60


class InvalidSignature(ValueError):
    pass


def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidSignature("Invalid collector authorization")
        result[key] = value
    return result


def b64(value: str) -> bytes:
    if not re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", value):
        raise InvalidSignature("Invalid collector authorization")
    try:
        return base64.b64decode(
            value.rstrip("=") + "=" * (-len(value.rstrip("=")) % 4), altchars=b"-_", validate=True
        )
    except (ValueError, binascii.Error):
        raise InvalidSignature("Invalid collector authorization") from None


class QStashVerifier:
    def __init__(self, destination: str, current: SecretStr, next_key: SecretStr) -> None:
        from urllib.parse import urlsplit

        url = urlsplit(destination)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username
            or url.password
            or url.query
            or url.fragment
            or url.path != "/internal/collect/ovation"
        ):
            raise ValueError("Configure the exact HTTPS collector destination")
        if any(len(key.get_secret_value()) < 32 for key in (current, next_key)):
            raise ValueError("Both securely supplied signing keys are required")
        self.destination, self.current, self.next_key = destination, current, next_key

    def verify(self, token: str, body: bytes, at: datetime) -> str:
        if len(token) > 8192 or len(body) > 256:
            raise InvalidSignature("Invalid collector authorization")
        try:
            head, payload, signature = token.split(".")
            header = json.loads(b64(head), object_pairs_hook=unique)
            claims = json.loads(b64(payload), object_pairs_hook=unique)
            if not isinstance(header, dict) or not isinstance(claims, dict):
                raise InvalidSignature("Invalid collector authorization")
            if header.get("alg") != "HS256" or set(header) - {"alg", "typ"}:
                raise InvalidSignature("Invalid collector authorization")
            if header.get("typ", "JWT") != "JWT":
                raise InvalidSignature("Invalid collector authorization")
            signed = (head + "." + payload).encode("ascii")
            received = b64(signature)
            matches = [
                hmac.compare_digest(
                    hmac.new(key.get_secret_value().encode(), signed, hashlib.sha256).digest(),
                    received,
                )
                for key in (self.current, self.next_key)
            ]
            if not any(matches):
                raise InvalidSignature("Invalid collector authorization")
            now = utc(at).timestamp()
            if any(type(claims.get(key)) is not int for key in ("iat", "nbf", "exp")):
                raise InvalidSignature("Invalid collector authorization")
            if not (
                claims["nbf"] <= now + CLOCK_LEEWAY
                and now < claims["exp"]
                and -CLOCK_LEEWAY <= now - claims["iat"] <= 300
                and 0 < claims["exp"] - claims["iat"] <= 300
                and claims["nbf"] <= claims["exp"]
            ):
                raise InvalidSignature("Invalid collector authorization")
            if claims.get("iss") != "Upstash" or claims.get("sub") != self.destination:
                raise InvalidSignature("Invalid collector authorization")
            digest = b64(claims["body"])
            if not hmac.compare_digest(digest, hashlib.sha256(body).digest()):
                raise InvalidSignature("Invalid collector authorization")
            identity = claims.get("jti")
            if not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", identity):
                raise InvalidSignature("Invalid collector authorization")
            return hashlib.sha256(identity.encode()).hexdigest()
        except InvalidSignature:
            raise
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError, AttributeError):
            raise InvalidSignature("Invalid collector authorization") from None
