import os
from collections.abc import Mapping
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Settings(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, validate_default=True)
    profile: Literal["mvp", "development"] = "mvp"
    mode: Literal["offline"] = "offline"
    host: Literal["127.0.0.1", "::1", "0.0.0.0"] = "127.0.0.1"
    allow_network: bool = False
    provider_network: bool = False
    cache_path: Path = Path("var/providers.sqlite")
    response_deadline: float = Field(default=3.0, ge=0.01, le=10.0)
    contract_path: Path = Path(__file__).resolve().parents[4] / "api" / "openapi.json"
    port: int = Field(default=8000, ge=1024, le=65535)
    fixture_dir: Path = Path(__file__).resolve().parents[4] / "api" / "examples"

    @field_validator("fixture_dir")
    @classmethod
    def existing_fixtures(cls, value: Path) -> Path:
        value = value.resolve()
        return value

    @model_validator(mode="after")
    def explicit_network_binding(self) -> "Settings":
        if self.profile == "development" and (
            not self.fixture_dir.is_dir()
            or not (self.fixture_dir / "daylight-next-window.json").is_file()
        ):
            raise ValueError("Fixture directory must contain the repository's synthetic examples")
        if self.host == "0.0.0.0" and not self.allow_network:
            raise ValueError("Network binding requires explicit AURORA_ALLOW_NETWORK=true")
        return self

    @classmethod
    def from_environment(cls, env: Mapping[str, str] | None = None) -> "Settings":
        source = os.environ if env is None else env
        keys = {
            "AURORA_PROFILE": "profile",
            "AURORA_MODE": "mode",
            "AURORA_PROVIDER_NETWORK": "provider_network",
            "AURORA_CACHE_PATH": "cache_path",
            "AURORA_RESPONSE_DEADLINE": "response_deadline",
            "AURORA_CONTRACT_PATH": "contract_path",
            "AURORA_ALLOW_NETWORK": "allow_network",
            "AURORA_HOST": "host",
            "AURORA_PORT": "port",
            "AURORA_FIXTURE_DIR": "fixture_dir",
        }
        unexpected = {key for key in source if key.startswith("AURORA_")} - keys.keys()
        if unexpected:
            raise ValueError("Unknown AURORA configuration keys: " + ", ".join(sorted(unexpected)))
        # Pydantic validates strings supplied by environment variables.
        return cls.model_validate(
            {field: source[key] for key, field in keys.items() if key in source}
        )
