from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi import HTTPException


def test_offline_voice_messages_returns_503_before_quota_files_or_provider() -> None:
    from routers import chat

    with patch.object(chat, 'is_offline_runtime', return_value=True), patch.object(
        chat, 'enforce_chat_quota', side_effect=AssertionError('quota/provider path reached')
    ), patch.object(chat, 'retrieve_file_paths', side_effect=AssertionError('file path reached')), patch.object(
        chat, 'get_prerecorded_service', side_effect=AssertionError('provider selection reached')
    ):
        with pytest.raises(HTTPException) as error:
            chat.create_voice_message_stream(files=[], uid='offline-user')

    assert error.value.status_code == 503


@pytest.mark.asyncio
async def test_offline_voice_transcribe_returns_503_before_body_or_provider() -> None:
    from routers import chat

    with patch.object(chat, 'is_offline_runtime', return_value=True), patch.object(
        chat, 'is_trial_paywalled', side_effect=AssertionError('quota path reached')
    ), patch.object(chat, 'get_prerecorded_service', side_effect=AssertionError('provider selection reached')):
        with pytest.raises(HTTPException) as error:
            await chat.transcribe_voice_message(request=None, uid='offline-user')

    assert error.value.status_code == 503
