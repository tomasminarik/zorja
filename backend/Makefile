.PHONY: setup check serve replay
UV ?= $(if $(wildcard .runtime/tooling/bin/uv),.runtime/tooling/bin/uv,uv)

setup:
	$(UV) sync --locked

check:
	$(UV) run --frozen ruff format --check .
	$(UV) run --frozen ruff check .
	$(UV) run --frozen mypy
	$(UV) run --frozen pytest
	$(UV) run --frozen python ../tools/check_contract.py

serve:
	$(UV) run --frozen aurora-backend serve

replay:
	$(UV) run --frozen aurora-backend replay daylight-next-window
