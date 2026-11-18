"""Use the locked IANA database rather than host-specific timezone files."""

from functools import lru_cache
from importlib.resources import files
from zoneinfo import ZoneInfo


@lru_cache(maxsize=1)
def names() -> frozenset[str]:
    return frozenset(files("tzdata").joinpath("zones").read_text().splitlines())


@lru_cache(maxsize=128)
def iana_zone(name: str) -> ZoneInfo:
    if name not in names():
        raise ValueError("A valid IANA timezone is required")
    with files("tzdata.zoneinfo").joinpath(*name.split("/")).open("rb") as stream:
        return ZoneInfo.from_file(stream, key=name)
