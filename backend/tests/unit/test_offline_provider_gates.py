from __future__ import annotations

from unittest.mock import patch

import pytest

from utils.stt.outcomes import TranscriptionFailure


def test_offline_prerecorded_selection_fails_before_provider_choice() -> None:
    from utils.stt.pre_recorded import get_prerecorded_service

    with patch.dict('os.environ', {'OMI_ENV_STAGE': 'offline'}, clear=False):
        with pytest.raises(TranscriptionFailure):
            get_prerecorded_service('en')


def test_offline_managed_deepgram_client_is_never_constructed() -> None:
    from utils.stt.streaming import _build_managed_deepgram_client

    with patch.dict('os.environ', {'OMI_ENV_STAGE': 'offline', 'DEEPGRAM_API_KEY': 'must-not-be-used'}, clear=False), patch(
        'utils.stt.streaming.DeepgramClient'
    ) as client:
        assert _build_managed_deepgram_client() is None

    client.assert_not_called()


def test_offline_product_telemetry_never_loads_posthog() -> None:
    from utils import product_telemetry

    with patch.dict('os.environ', {'OMI_ENV_STAGE': 'offline', 'POSTHOG_API_KEY': 'must-not-be-used'}, clear=False), patch(
        'utils.product_telemetry.importlib.import_module'
    ) as importer:
        product_telemetry.emit_product_event(uid='local-user', event='local-event', properties={})

    importer.assert_not_called()
