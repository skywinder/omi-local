SHELL := bash
export PYTHON ?= $(CURDIR)/backend/.venv/bin/python
export PROVIDER_MODE := offline

.PHONY: dev-check dev-up dev-status dev-audio-smoke dev-down test-offline

dev-check:
	bash scripts/dev-harness/dev-check.sh

dev-up:
	bash scripts/dev-harness/dev-up.sh

dev-status:
	bash scripts/dev-harness/dev-status.sh

dev-audio-smoke:
	bash scripts/dev-harness/audio-capture-smoke.sh

dev-down:
	bash scripts/dev-harness/dev-down.sh

test-offline:
	cd backend && env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider tests/unit/test_offline_audio_capture.py tests/unit/test_offline_network_policy.py tests/unit/test_offline_route_policy.py tests/unit/test_offline_main_surface.py tests/unit/test_offline_provider_gates.py tests/unit/test_offline_voice_message_routes.py
	env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider scripts/dev-harness/tests/test_safety.py scripts/dev-harness/tests/test_cli.py scripts/dev-harness/tests/test_env_stage.py
