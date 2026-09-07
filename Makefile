SHELL := bash
export PYTHON ?= $(CURDIR)/backend/.venv/bin/python
export PROVIDER_MODE := offline

.PHONY: dev-check dev-up dev-status dev-audio-smoke dev-down test-offline test-transport-unit test-transport-app

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

test-transport-unit:
	cd backend && env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -p no:cacheprovider tests/unit/test_local_transport_auth.py tests/unit/test_offline_audio_capture.py
	env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -p no:cacheprovider scripts/dev-harness/tests/test_local_mac.py

test-transport-app:
	cd app && bash test.sh test/unit/local_mac_session_test.dart test/widgets/local_mac_page_test.dart test/unit/offline_network_policy_test.dart test/unit/pure_socket_auth_test.dart test/unit/authenticated_request_401_test.dart test/unit/auth_refresh_timeout_test.dart test/unit/startup_auth_timeout_test.dart test/widgets/session_expired_reauthentication_test.dart
	cd app && bash scripts/analyze_ratchet.sh

test-offline:
	env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider scripts/dev-harness/tests/test_local_mac.py
	cd backend && env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider tests/unit/test_local_transport_auth.py tests/unit/test_verify_token_admin_and_local_dev_gating.py
	cd backend && env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider tests/unit/test_offline_audio_capture.py tests/unit/test_offline_network_policy.py tests/unit/test_offline_route_policy.py tests/unit/test_offline_main_surface.py tests/unit/test_offline_provider_gates.py tests/unit/test_offline_voice_message_routes.py
	env -u PROVIDER_MODE PYTHONDONTWRITEBYTECODE=1 "$${PYTHON}" -m pytest -q -x -p no:cacheprovider scripts/dev-harness/tests/test_safety.py scripts/dev-harness/tests/test_cli.py scripts/dev-harness/tests/test_env_stage.py
