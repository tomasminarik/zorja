"""Candidate source isolation and import checks; never contact hosting services."""

import hashlib
import json
import os
import runpy
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
prepare = runpy.run_path(str(ROOT / "backend/tools/prepare_vercel_bundle.py"))["prepare"]


def test_bundle_isolated_import_and_default_route_safety(tmp_path):
    destination = tmp_path / "candidate"
    hashes = prepare(ROOT, destination)
    for name, digest in hashes.items():
        assert hashlib.sha256((destination / name).read_bytes()).hexdigest() == digest
    assert (destination / "requirements.txt").read_bytes() == (
        ROOT / "backend/requirements.lock"
    ).read_bytes()
    assert (destination / "api/openapi.json").read_bytes() == (
        ROOT / "api/openapi.json"
    ).read_bytes()
    assert "aurora_backend/providers/redis_store.py" in hashes
    assert not any(".runtime" in name or ".env" in name or ".sqlite" in name for name in hashes)
    assert json.loads((destination / "manifest.json").read_text()) == hashes
    config = json.loads((destination / "vercel.json").read_text())
    assert "crons" not in config and "env" not in config
    code = """
import asyncio
from pathlib import Path
import httpx
import main
assert Path(main.__file__).resolve().parent == Path.cwd()
import aurora_backend.api.hosted
assert Path(aurora_backend.api.hosted.__file__).is_relative_to(Path.cwd())
async def check():
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app),
                               base_url="https://synthetic.example") as client:
        # No lifespan means no clients are opened, and serving fails closed.
        assert (await client.get("/health/ready")).status_code == 503
asyncio.run(check())
"""
    env = {key: value for key, value in os.environ.items() if not key.startswith("AURORA_")}
    env.update(
        VERCEL_ENV="production",
        PYTHONPATH=str(destination),
        AURORA_HOSTED_REDIS_URL="https://synthetic.upstash.io",
        AURORA_HOSTED_REDIS_TOKEN="synthetic-token-with-no-account-access",
        AURORA_HOSTED_NAMESPACE="synthetic-candidate-v2",
    )
    subprocess.run([sys.executable, "-c", code], cwd=destination, env=env, check=True)
    for mode in ("preview", "development", ""):
        result = subprocess.run(
            [sys.executable, "-c", "import main"],
            cwd=destination,
            env={**env, "VERCEL_ENV": mode},
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert "Hosted previews and unselected environments are disabled" in result.stderr
    collection = {
        "AURORA_HOSTED_COLLECTION_ENABLED": "true",
        "AURORA_HOSTED_COLLECTOR_DESTINATION": "https://synthetic.example/internal/collect/ovation",
        "AURORA_HOSTED_SIGNING_CURRENT": "synthetic-current-" + "c" * 32,
        "AURORA_HOSTED_SIGNING_NEXT": "synthetic-next-" + "n" * 32,
    }
    # Complete collector configuration is accepted; a partial one stops startup.
    subprocess.run(
        [sys.executable, "-c", "import main"],
        cwd=destination,
        env={**env, **collection},
        check=True,
    )
    partial = {**env, **collection}
    del partial["AURORA_HOSTED_SIGNING_NEXT"]
    result = subprocess.run(
        [sys.executable, "-c", "import main"],
        cwd=destination,
        env=partial,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "Invalid Aurora hosted configuration" in result.stderr
    assert "synthetic-current" not in result.stderr


def test_bundle_does_not_overwrite_or_follow_source_links(tmp_path):
    destination = tmp_path / "existing"
    destination.mkdir()
    marker = destination / "keep"
    marker.write_text("preserve")
    with pytest.raises(FileExistsError):
        prepare(ROOT, destination)
    assert marker.read_text() == "preserve"
    synthetic = tmp_path / "source"
    package = synthetic / "backend/src/aurora_backend/api"
    package.mkdir(parents=True)
    (synthetic / "api").mkdir()
    (synthetic / "api/openapi.json").write_text("{}")
    (synthetic / "backend/requirements.lock").write_text("")
    (package / "hosted.py").symlink_to(marker)
    with pytest.raises(ValueError, match="regular repository files"):
        prepare(synthetic, tmp_path / "blocked")
    assert not (tmp_path / "blocked").exists()
