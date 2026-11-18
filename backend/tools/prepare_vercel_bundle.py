"""Prepare a source allow-listed forecast bundle locally; never calls Vercel."""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

ENTRYPOINT = '''"""Hosted entrypoint; the collector route exists only when configured."""
import os
import sys
from pathlib import Path

from aurora_backend.api.hosted import create_hosted_app
from aurora_backend.config.hosted import HostedSettings

if sys.version_info[:3] < (3, 13, 16) or sys.version_info[:2] != (3, 13):
    raise RuntimeError("The approved Python 3.13.16+ runtime is required")
if os.environ.get("VERCEL_ENV") != "production":
    raise RuntimeError("Hosted previews and unselected environments are disabled")

root = Path(__file__).resolve().parent
config = HostedSettings.from_environment({
    **os.environ,
    "AURORA_HOSTED_CONTRACT_PATH": str(root / "api" / "openapi.json"),
})
app = create_hosted_app(config)
'''


def prepare(root: Path, destination: Path) -> dict[str, str]:
    root = root.resolve()
    source = root / "backend/src/aurora_backend"
    selected = [path for path in source.rglob("*") if path.suffix == ".py"]
    selected += [root / "api/openapi.json", root / "backend/requirements.lock"]
    # Never follow source links into private/runtime files or overwrite an existing artifact.
    if any(path.is_symlink() or not path.is_file() for path in selected):
        raise ValueError("Bundle inputs must be regular repository files")
    if not selected or not (source / "api/hosted.py").is_file():
        raise ValueError("The hosted backend source is required")
    destination.mkdir(parents=True, exist_ok=False)
    try:
        for path in selected:
            if path.is_relative_to(source):
                relative = Path("aurora_backend") / path.relative_to(source)
            elif path.name == "requirements.lock":
                relative = Path("requirements.txt")
            else:
                relative = Path("api/openapi.json")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
        (destination / "main.py").write_text(ENTRYPOINT)
        (destination / ".python-version").write_bytes(
            (root / "backend/.python-version").read_bytes()
        )
        (destination / "vercel.json").write_text(
            json.dumps(
                {
                    "$schema": "https://openapi.vercel.sh/vercel.json",
                    "framework": "fastapi",
                    "regions": ["fra1"],
                    "functions": {"main.py": {"maxDuration": 15}},
                    "installCommand": "python -m pip install --require-hashes -r requirements.txt",
                },
                indent=2,
            )
            + "\n"
        )
        hashes = {
            str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(destination.rglob("*"))
            if path.is_file()
        }
        (destination / "manifest.json").write_text(json.dumps(hashes, indent=2) + "\n")
        return hashes
    except BaseException:
        shutil.rmtree(destination)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    files = prepare(Path(__file__).resolve().parents[2], args.output)
    print(f"Prepared {len(files)} source files with checksums; no deployment performed.")
