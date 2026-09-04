from __future__ import annotations

import json
import os
import uuid
import wave
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import pytest

from utils.offline_audio_capture import (
    METADATA_NAME,
    METADATA_PART_NAME,
    PCM_PART_NAME,
    WAV_NAME,
    create_offline_omi_capture,
    recover_offline_audio_captures,
)


@contextmanager
def _offline_storage(tmp_path: Path):
    state_root = tmp_path / 'state'
    storage_root = state_root / 'services' / 'storage'
    env = {
        'OMI_ENV_STAGE': 'offline',
        'PROVIDER_MODE': 'offline',
        'OMI_HARNESS_STATE_ROOT': str(state_root),
        'OMI_LOCAL_STORAGE_ROOT': str(storage_root),
        'FIREBASE_PROJECT_ID': 'demo-omi-local',
        'FIRESTORE_EMULATOR_HOST': '127.0.0.1:8085',
    }
    with patch.dict(os.environ, env, clear=True):
        yield storage_root


def _new_capture(tmp_path: Path, *, session_id: str | None = None):
    with _offline_storage(tmp_path):
        return create_offline_omi_capture(
            session_id=session_id or str(uuid.uuid4()),
            source='omi',
            input_codec='opus_fs320',
            sample_rate=16000,
            channels=1,
        )


def test_finalize_creates_atomic_pcm16_wav_and_technical_metadata(tmp_path: Path) -> None:
    capture = _new_capture(tmp_path)
    assert capture is not None
    pcm = b'\x01\x00\xff\xff' * 160
    capture.record_decoded_frame(encoded_bytes=23, pcm=pcm)
    metadata = capture.finalize()

    with wave.open(str(capture.session_dir / WAV_NAME), 'rb') as source:
        assert source.getnchannels() == 1
        assert source.getsampwidth() == 2
        assert source.getframerate() == 16000
        assert source.readframes(source.getnframes()) == pcm
    persisted = json.loads((capture.session_dir / METADATA_NAME).read_text(encoding='utf-8'))
    assert persisted == metadata
    assert persisted['status'] == 'completed'
    assert persisted['input'] == {'codec': 'opus_fs320', 'sample_rate': 16000, 'channels': 1}
    assert persisted['output']['codec'] == 'pcm_s16le'
    assert persisted['frames_received'] == 1
    assert persisted['encoded_bytes'] == 23
    assert persisted['decoded_pcm_bytes'] == len(pcm)
    assert not (capture.session_dir / PCM_PART_NAME).exists()
    assert not (capture.session_dir / METADATA_PART_NAME).exists()
    assert not any(path.name.endswith('.tmp') for path in capture.session_dir.iterdir())
    assert not any(key in persisted for key in ('uid', 'device_id', 'transcript'))


def test_each_capture_requires_a_unique_server_session_directory(tmp_path: Path) -> None:
    session_id = str(uuid.uuid4())
    first = _new_capture(tmp_path, session_id=session_id)
    assert first is not None
    with pytest.raises(FileExistsError):
        _new_capture(tmp_path, session_id=session_id)
    first.finalize()


@pytest.mark.parametrize(
    ('source', 'codec', 'sample_rate', 'channels'),
    [
        ('phone', 'opus', 16000, 1),
        ('omi', 'pcm8', 16000, 1),
        ('omi', 'opus', 8000, 1),
        ('omi', 'opus', 16000, 2),
    ],
)
def test_capture_gate_accepts_only_offline_omi_opus_mono_16k(
    tmp_path: Path, source: str, codec: str, sample_rate: int, channels: int
) -> None:
    with _offline_storage(tmp_path):
        if source != 'omi':
            assert (
                create_offline_omi_capture(
                    session_id=str(uuid.uuid4()),
                    source=source,
                    input_codec=codec,
                    sample_rate=sample_rate,
                    channels=channels,
                )
                is None
            )
        else:
            with pytest.raises(RuntimeError):
                create_offline_omi_capture(
                    session_id=str(uuid.uuid4()),
                    source=source,
                    input_codec=codec,
                    sample_rate=sample_rate,
                    channels=channels,
                )


def test_capture_requires_validated_owned_storage_root(tmp_path: Path) -> None:
    with patch.dict(os.environ, {'OMI_ENV_STAGE': 'offline'}, clear=True):
        with pytest.raises(RuntimeError, match='OMI_LOCAL_STORAGE_ROOT'):
            create_offline_omi_capture(
                session_id=str(uuid.uuid4()),
                source='omi',
                input_codec='opus',
                sample_rate=16000,
                channels=1,
            )


def test_startup_recovery_preserves_pcm_and_marks_metadata_recovered(tmp_path: Path) -> None:
    with _offline_storage(tmp_path):
        capture = create_offline_omi_capture(
            session_id=str(uuid.uuid4()),
            source='omi',
            input_codec='opus',
            sample_rate=16000,
            channels=1,
        )
        assert capture is not None
        pcm = b'\x00\x00' * 320
        capture.record_decoded_frame(encoded_bytes=18, pcm=pcm)
        capture._pcm.close()

        assert recover_offline_audio_captures() == (1, 0)

    metadata = json.loads((capture.session_dir / METADATA_NAME).read_text(encoding='utf-8'))
    assert metadata['status'] == 'recovered'
    assert metadata['decoded_pcm_bytes'] == len(pcm)
    assert (capture.session_dir / WAV_NAME).is_file()
    assert not (capture.session_dir / PCM_PART_NAME).exists()


def test_recovery_ignores_stale_atomic_temporary_files(tmp_path: Path) -> None:
    with _offline_storage(tmp_path):
        capture = create_offline_omi_capture(
            session_id=str(uuid.uuid4()),
            source='omi',
            input_codec='opus',
            sample_rate=16000,
            channels=1,
        )
        assert capture is not None
        capture.record_decoded_frame(encoded_bytes=18, pcm=b'\x00\x00' * 320)
        capture._pcm.close()
        (capture.session_dir / '.audio.wav.stale.tmp').write_bytes(b'incomplete')
        (capture.session_dir / '.metadata.json.stale.tmp').write_text('{broken', encoding='utf-8')

        assert recover_offline_audio_captures() == (1, 0)

    assert (capture.session_dir / WAV_NAME).is_file()
    assert json.loads((capture.session_dir / METADATA_NAME).read_text(encoding='utf-8'))['status'] == 'recovered'


def test_failed_recovery_leaves_original_part_untouched(tmp_path: Path) -> None:
    with _offline_storage(tmp_path):
        capture = create_offline_omi_capture(
            session_id=str(uuid.uuid4()),
            source='omi',
            input_codec='opus',
            sample_rate=16000,
            channels=1,
        )
        assert capture is not None
        capture.record_decoded_frame(encoded_bytes=18, pcm=b'\x00\x00' * 10)
        capture._pcm.close()
        original = capture.pcm_part_path.read_bytes()
        capture.metadata_part_path.write_text('{broken', encoding='utf-8')

        assert recover_offline_audio_captures() == (0, 1)

    assert capture.pcm_part_path.read_bytes() == original
    assert not (capture.session_dir / WAV_NAME).exists()
