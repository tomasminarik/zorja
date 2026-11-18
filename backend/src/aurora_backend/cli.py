import argparse
import asyncio
import json
from pathlib import Path

import uvicorn

from aurora_backend.api.app import create_app
from aurora_backend.api.replay import CITIES, replay_forecast
from aurora_backend.config.settings import Settings
from aurora_backend.providers.diagnostics import inspect_sources
from aurora_backend.providers.models import ProviderError


def main() -> None:
    parser = argparse.ArgumentParser(description="Local offline aurora development service")
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("serve")
    forecast_replay = subcommands.add_parser("forecast-replay")
    forecast_replay.add_argument("city", choices=sorted(CITIES))
    forecast_replay.add_argument(
        "--capture-dir", type=Path, default=Path("tests/fixtures/providers/captured")
    )
    replay = subcommands.add_parser("replay")
    replay.add_argument("scenario")
    providers = subcommands.add_parser("providers", help="Explicit opt-in source diagnostics")
    providers.add_argument("--allow-provider-network", action="store_true")
    providers.add_argument("--cache-path", type=Path, default=Path("var/providers.sqlite"))
    providers.add_argument("--latitude", type=float, default=59.3293)
    providers.add_argument("--longitude", type=float, default=18.0686)
    args = parser.parse_args()
    if args.command == "forecast-replay":
        print(json.dumps(asyncio.run(replay_forecast(args.city, args.capture_dir)), indent=2))
        return
    if args.command == "providers":
        if not args.allow_provider_network:
            parser.error("Provider diagnostics require --allow-provider-network")
        try:
            print(
                json.dumps(
                    asyncio.run(
                        inspect_sources(
                            args.cache_path,
                            args.latitude,
                            args.longitude,
                        )
                    ),
                    indent=2,
                )
            )
        except ProviderError as error:
            parser.error(error.code)
        return
    config = Settings.from_environment()
    if args.command == "serve":
        uvicorn.run(create_app(config), host=config.host, port=config.port, access_log=False)
    else:
        scenarios = {path.stem: path for path in config.fixture_dir.glob("*.json")}
        if args.scenario not in scenarios:
            parser.error("Unknown scenario; choose from: " + ", ".join(sorted(scenarios)))
        # Preserve original fixture times and locations; never masquerade as a fresh forecast.
        print(json.dumps(json.loads(scenarios[args.scenario].read_text()), indent=2))


if __name__ == "__main__":
    main()
