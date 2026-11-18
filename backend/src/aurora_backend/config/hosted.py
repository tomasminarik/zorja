"""Explicit hosted composition configuration; never selected by the local CLI."""

import re
from collections.abc import Mapping
from pathlib import Path

import httpx
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator, model_validator

from aurora_backend.collection.signatures import QStashVerifier
from aurora_backend.providers.budgets import SharedLimits


class HostedSettings(BaseModel):
    # Suppress all input values in validation errors, including malformed secret inputs.
    model_config = ConfigDict(extra="forbid", frozen=True, hide_input_in_errors=True)
    redis_url: str = Field(repr=False)
    redis_token: SecretStr
    namespace: str
    contract_path: Path
    collection_enabled: bool = False
    collector_destination: str | None = Field(default=None, repr=False)
    signing_current: SecretStr | None = None
    signing_next: SecretStr | None = None
    response_deadline: float = Field(default=3, ge=0.01, le=10)
    limits: SharedLimits = Field(default_factory=SharedLimits)

    @field_validator("redis_url")
    @classmethod
    def redis_endpoint(cls, value: str) -> str:
        try:
            url = httpx.URL(value)
            valid = (
                url.scheme == "https"
                and url.host.endswith(".upstash.io")
                and url.port in (None, 443)
                and url.path in ("", "/")
                and not (url.query or url.fragment or url.userinfo)
            )
        except Exception:
            valid = False
        if not valid:
            raise ValueError("A private Upstash HTTPS root endpoint is required")
        return value

    @field_validator("redis_token", "signing_current", "signing_next")
    @classmethod
    def secret_value(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None:
            raw = value.get_secret_value()
            if not raw or raw.strip() != raw or any(ord(c) < 33 or ord(c) > 126 for c in raw):
                raise ValueError("A nonempty printable secret without whitespace is required")
        return value

    @field_validator("namespace")
    @classmethod
    def bounded_namespace(cls, value: str) -> str:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", value):
            raise ValueError("An explicit bounded persistent namespace is required")
        return value

    @model_validator(mode="after")
    def collection_configuration(self) -> "HostedSettings":
        values = (self.collector_destination, self.signing_current, self.signing_next)
        if self.collection_enabled:
            if any(value is None for value in values):
                raise ValueError("Collection requires destination and both signing keys")
            assert self.collector_destination and self.signing_current and self.signing_next
            QStashVerifier(self.collector_destination, self.signing_current, self.signing_next)
        elif any(value is not None for value in values):
            raise ValueError("Remove collector configuration when collection is disabled")
        return self

    @classmethod
    def from_environment(cls, source: Mapping[str, str]) -> "HostedSettings":
        keys = {
            "AURORA_HOSTED_REDIS_URL": "redis_url",
            "AURORA_HOSTED_REDIS_TOKEN": "redis_token",
            "AURORA_HOSTED_NAMESPACE": "namespace",
            "AURORA_HOSTED_CONTRACT_PATH": "contract_path",
            "AURORA_HOSTED_COLLECTION_ENABLED": "collection_enabled",
            "AURORA_HOSTED_COLLECTOR_DESTINATION": "collector_destination",
            "AURORA_HOSTED_SIGNING_CURRENT": "signing_current",
            "AURORA_HOSTED_SIGNING_NEXT": "signing_next",
            "AURORA_HOSTED_RESPONSE_DEADLINE": "response_deadline",
        }
        # Do not silently accept local/development/notification switches here.
        if any(key.startswith("AURORA_") and key not in keys for key in source):
            raise ValueError("Unsupported Aurora hosted configuration")
        try:
            return cls.model_validate(
                {field: source[key] for key, field in keys.items() if key in source}
            )
        except ValueError:
            # ValidationError.errors() can contain input values despite safe str().
            # Environment entrypoint deliberately exposes only a generic error.
            raise ValueError("Invalid Aurora hosted configuration") from None
