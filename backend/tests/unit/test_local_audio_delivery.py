from __future__ import annotations

import hashlib
import json
import struct
import uuid
import wave
from pathlib import Path

import pytest

from utils.local_audio_delivery import DeliveryConflict, MAGIC, accept_part, parse_part
from utils.opus_preroll import decode_fresh_audio, validate_preroll


def part(
    *frames: bytes, source: str = 'phone', codec: str = 'pcm16', preroll_frames=None, index: int = 0, version=None
) -> bytes:
    fields = {
        'version': version if version is not None else 2 if preroll_frames is not None else 1,
        'id': str(uuid.uuid4()),
        'recording_id': str(uuid.uuid4()),
        'index': index,
        'source': source,
        'codec': codec,
        'server_id': 'a' * 64,
        'started_at': '2026-10-27T08:00:00Z',
    }
    if preroll_frames is not None:
        fields['preroll_frames'] = preroll_frames
    header = json.dumps(fields).encode()
    return (
        MAGIC
        + struct.pack('>I', len(header))
        + header
        + b''.join(struct.pack('>I', len(frame)) + frame for frame in frames)
    )


def test_lost_ack_retry_after_restart_publishes_one_identical_wav(tmp_path: Path):
    body = part(b'\x01\x00' * 160, b'\xff\xff' * 160)
    first = accept_part(body, tmp_path)
    # A fresh invocation has no process-local deduplication state.
    second = accept_part(body, tmp_path)
    assert (
        first == second == {'id': parse_part(body)[0]['id'], 'sha256': hashlib.sha256(body).hexdigest(), 'stored': True}
    )
    captures = list((tmp_path / 'listen-captures').iterdir())
    assert len(captures) == 1
    with wave.open(str(captures[0] / 'audio.wav')) as audio:
        assert audio.readframes(320) == b'\x01\x00' * 160 + b'\xff\xff' * 160
    metadata = json.loads((captures[0] / 'metadata.json').read_text())
    assert metadata['frames_received'] == 2
    assert metadata['started_at'] == '2026-10-27T08:00:00Z'
    assert metadata['delivery']['recording_id'] == parse_part(body)[0]['recording_id']
    assert list((tmp_path / 'local-audio-staging').iterdir()) == []


def test_same_id_with_changed_bytes_is_rejected_without_overwriting_audio(tmp_path: Path):
    body = part(b'\x01\x00' * 160)
    accept_part(body, tmp_path)
    before = {path: path.read_bytes() for path in (tmp_path / 'listen-captures').glob('*/*')}
    with pytest.raises(DeliveryConflict):
        accept_part(body[:-1] + b'\x01', tmp_path)
    assert all(path.read_bytes() == content for path, content in before.items())


@pytest.mark.parametrize('mutate', [lambda b: b[:-1], lambda b: b[:15], lambda b: b'wrong' + b[5:]])
def test_incomplete_and_corrupt_parts_never_publish_or_ack(tmp_path: Path, mutate):
    with pytest.raises(ValueError):
        accept_part(mutate(part(b'\x00\x00' * 160)), tmp_path)
    assert not (tmp_path / 'listen-captures').exists()


def test_opus_packets_decode_in_original_order_with_one_decoder(tmp_path: Path):
    observed = []

    class Decoder:
        def decode(self, frame, *, frame_size):
            observed.append(frame)
            assert frame_size == 1920
            return frame * 2

    body = part(b'\x01', b'\x02', source='omi', codec='opus_fs320')
    receipt = accept_part(body, tmp_path, decoder_factory=Decoder)
    assert observed == [b'\x01', b'\x02']
    with wave.open(str(tmp_path / 'listen-captures' / receipt['id'] / 'audio.wav')) as audio:
        assert audio.readframes(2) == b'\x01\x01\x02\x02'


def test_disk_sync_failure_never_returns_a_receipt(tmp_path: Path, monkeypatch):
    import utils.local_audio_delivery as delivery

    monkeypatch.setattr(delivery.os, 'fsync', lambda _: (_ for _ in ()).throw(OSError('synthetic disk failure')))
    with pytest.raises(OSError):
        accept_part(part(b'\x00\x00' * 160), tmp_path)
    assert list((tmp_path / 'listen-captures').iterdir()) == []


def test_preroll_helper_decodes_context_but_returns_only_fresh_stateful_samples():
    from collections import deque

    history = deque(maxlen=4)

    def decode(frame):
        history.append(frame[1])
        return struct.pack('<h', sum(history)) * 320

    frames = [bytes([0x78, value]) for value in range(1, 7)]
    count = validate_preroll({'version': 2, 'codec': 'opus_fs320', 'index': 1, 'preroll_frames': 4}, frames)
    assert (
        decode_fresh_audio(frames, count, decode, limit=32000)
        == struct.pack('<h', 14) * 320 + struct.pack('<h', 18) * 320
    )


def test_preroll_helper_rejects_prefix_only_pcm_and_excess_context():
    for header, frames in [
        ({'version': 2, 'codec': 'pcm16', 'index': 1, 'preroll_frames': 4}, [b'\x78\x00'] * 5),
        ({'version': 2, 'codec': 'opus', 'index': 1, 'preroll_frames': 4}, [b'\x78\x00'] * 4),
        ({'version': 2, 'codec': 'opus', 'index': 1, 'preroll_frames': 5}, [b'\x78\x00'] * 6),
        ({'version': 1, 'codec': 'opus', 'index': 1, 'preroll_frames': 4}, [b'\x78\x00'] * 5),
        ({'version': 2, 'codec': 'opus', 'index': 1}, [b'\x78\x00'] * 5),
    ]:
        with pytest.raises(ValueError):
            validate_preroll(header, frames)


def test_opus_preroll_warms_one_decoder_but_does_not_duplicate_audio_duration_or_counters(tmp_path: Path):
    from collections import deque

    decoded_order = []

    class StatefulDecoder:
        def __init__(self):
            self.history = deque(maxlen=4)

        def decode(self, frame, *, frame_size):
            assert frame_size == 1920
            self.history.append(frame[1])
            decoded_order.append(frame[1])
            return struct.pack('<h', sum(self.history)) * 320  # One 20 ms packet.

    frames = [bytes([0x78, value]) for value in range(1, 7)]
    body = part(*frames, source='omi', codec='opus_fs320', preroll_frames=4, index=1)
    saved = accept_part(body, tmp_path, decoder_factory=StatefulDecoder)
    assert decoded_order == [1, 2, 3, 4, 5, 6]
    with wave.open(str(tmp_path / 'listen-captures' / saved['id'] / 'audio.wav')) as audio:
        assert audio.getnframes() == 640
        assert audio.readframes(640) == struct.pack('<h', 14) * 320 + struct.pack('<h', 18) * 320
    metadata = json.loads((tmp_path / 'listen-captures' / saved['id'] / 'metadata.json').read_text())
    assert metadata['duration_seconds'] == 0.04
    assert metadata['frames_received'] == 2
    assert metadata['encoded_bytes'] == 4
    assert metadata['delivery']['preroll_frames'] == 4
    assert accept_part(body, tmp_path, decoder_factory=lambda: pytest.fail('Retry must not decode again')) == saved


@pytest.mark.parametrize(
    'count,index,toc,packets,codec',
    [
        (-1, 1, 0x78, 6, 'opus'),
        (True, 1, 0x78, 6, 'opus'),
        ('4', 1, 0x78, 6, 'opus'),
        (33, 1, 0x80, 34, 'opus'),
        (4, 0, 0x78, 6, 'opus'),
        (4, 1, 0x78, 4, 'opus'),  # Prefix with no new audio.
        (4, 1, 0x80, 6, 'opus'),  # Only 10 ms: insufficient decoder warm-up.
        (2, 1, 0x1B, 3, 'opus'),  # Zero/invalid Opus packet frame count.
        (3, 1, 0x18, 4, 'opus'),  # 180 ms could use the last 120 ms; not a minimal suffix.
        (5, 1, 0x78, 6, 'opus'),  # 100 ms could use the last 80 ms.
        (4, 1, 0x78, 6, 'pcm16'),
    ],
)
def test_invalid_preroll_is_rejected_before_any_capture_is_created(tmp_path, count, index, toc, packets, codec):
    source = 'phone' if codec == 'pcm16' else 'omi'
    frames = [bytes([toc, 0]) for _ in range(packets)]
    with pytest.raises(ValueError):
        accept_part(part(*frames, source=source, codec=codec, preroll_frames=count, index=index), tmp_path)
    assert not (tmp_path / 'listen-captures').exists()


def test_legacy_part_without_preroll_field_keeps_all_audio(tmp_path):
    body = part(b'\x01\x00' * 320)
    assert 'preroll_frames' not in parse_part(body)[0]
    saved = accept_part(body, tmp_path)
    metadata = json.loads((tmp_path / 'listen-captures' / saved['id'] / 'metadata.json').read_text())
    assert metadata['duration_seconds'] == 0.02
    assert metadata['delivery']['preroll_frames'] == 0


def test_v1_cannot_silently_opt_into_v2_preroll(tmp_path):
    with pytest.raises(ValueError):
        accept_part(
            part(*([b'\x78\x01'] * 5), source='omi', codec='opus', preroll_frames=4, index=1, version=1), tmp_path
        )
    assert not (tmp_path / 'listen-captures').exists()


def group_message(recording_id, index, offset, pcm=b'', *, finish=False, silence=30):
    fields = dict(version=3, group_version=1, kind='finish' if finish else 'audio',
                  id=recording_id if finish else str(uuid.uuid5(uuid.UUID(recording_id), str(index))),
                  recording_id=recording_id, index=index, source='phone', codec='pcm16',
                  server_id='a'*64, started_at='2026-11-20T08:00:00Z', group_started_at='2026-11-20T08:00:00Z',
                  preroll_frames=0, silence_seconds=silence, first_sample=offset)
    header = json.dumps(fields).encode()
    packets = [pcm[i:i+4000] for i in range(0, len(pcm), 4000)]
    return MAGIC + struct.pack('>I', len(header)) + header + b''.join(struct.pack('>I', len(p)) + p for p in packets)


def test_bad_neighbor_does_not_poison_group_and_disabled_splitting_preserves_silence(tmp_path):
    recording = str(uuid.uuid4())
    pcm = bytes(3200)
    args = {'silence': 0}
    first = group_message(recording, 0, 0, pcm, **args)
    second = group_message(recording, 1, 1600, pcm, **args)
    assert accept_part(first, tmp_path)['stored']
    with pytest.raises(DeliveryConflict, match='preceding part'):
        accept_part(group_message(recording, 1, 1601, pcm, **args), tmp_path)
    assert accept_part(second, tmp_path)['stored']
    finish = group_message(recording, 2, 0, finish=True, **args)
    assert accept_part(finish, tmp_path)['stored']
    audio_path, = (tmp_path / 'listen-captures').glob('*/audio.wav')
    with wave.open(str(audio_path)) as wav:
        assert wav.readframes(wav.getnframes()) == pcm * 2
    group = tmp_path / 'grouped-recordings' / recording
    assert not list(group.glob('parts/*/audio.wav'))
    assert accept_part(second, tmp_path)['stored']


def test_group_order_loss_replay_and_two_rotations_make_one_conversation(tmp_path):
    recording = str(uuid.uuid4())
    with wave.open(str(Path(__file__).parents[2] / 'testing/release_fixtures/transcription-release-probe.wav')) as audio:
        words = audio.readframes(audio.getnframes())
    pcm = (words * 125)[:610 * 32000]
    spans = [pcm[:300 * 32000], pcm[300 * 32000:600 * 32000], pcm[600 * 32000:]]
    bodies = [group_message(recording, i, i * 300 * 16000, span) for i, span in enumerate(spans)]
    end = group_message(recording, 3, 0, finish=True)
    for body in [end, bodies[2], bodies[0], bodies[2]]:
        accept_part(body, tmp_path)
    progress = tmp_path / 'grouped-recordings' / recording / 'progress.json'
    assert json.loads(progress.read_text())['waiting_for_parts'] is True
    assert not list((tmp_path / 'listen-captures').glob('*/audio.wav'))
    for body in [bodies[1], end, *bodies]:
        accept_part(body, tmp_path)
    assert json.loads(progress.read_text())['completed']
    audio_path, = (tmp_path / 'listen-captures').glob('*/audio.wav')
    group = json.loads(audio_path.with_name('metadata.json').read_text())['conversation_group']
    assert group['end_sample'] == len(pcm) // 2
    assert 'speech_end_sample' not in group  # Explicit Stop retains the whole waveform for inference.
    with wave.open(str(audio_path)) as audio:
        assert audio.readframes(audio.getnframes()) == pcm[group['start_sample']*2:]


def test_group_29_seconds_does_not_finish_30_does_and_next_voice_starts_new_card(tmp_path, monkeypatch):
    from utils import local_conversation_groups as groups
    # Inject known detector decisions; exercise the production journal, reducer and published WAVs.
    def decisions(self, pcm):
        voiced = [i for i in range(0, len(pcm), 32000) if pcm[i] == 1]
        return [(i//2, min(i//2 + 16000, len(pcm)//2)) for i in voiced]
    monkeypatch.setattr(groups.SpeechDetector, 'runs', decisions)
    recording = str(uuid.uuid4())
    voice, quiet = b'\x01\0' * 16000, b'\0\0' * 16000
    def send(i, offset, pcm):
        return accept_part(group_message(recording, i, offset*16000, pcm), tmp_path)
    send(0, 0, voice + quiet * 29)
    assert not list((tmp_path / 'listen-captures').glob('*/audio.wav'))
    send(1, 30, quiet + quiet * 3 + voice + quiet * 30 + quiet * 2)
    paths = list((tmp_path / 'listen-captures').glob('*/metadata.json'))
    assert len(paths) == 2
    boundaries = [json.loads(path.read_text())['conversation_group'] for path in paths]
    ranges = sorted((g['start_sample'], g['speech_end_sample'], g['end_sample']) for g in boundaries)
    assert ranges == [(0, 16000, 31 * 16000), (34 * 16000 - 3200, 35 * 16000, 65 * 16000)]
    accept_part(group_message(recording, 2, 0, finish=True), tmp_path)
    assert len(list((tmp_path / 'listen-captures').glob('*/audio.wav'))) == 2



def test_retry_after_older_publication_preserves_existing_metadata(tmp_path, monkeypatch):
    from utils import local_conversation_groups as groups

    publish = groups._publish
    monkeypatch.setattr(groups.SpeechDetector, 'runs', lambda _self, _pcm: [(0, 16000)])

    def interrupt_after_legacy_publication(root, group, config, index, start, end, speech_end):
        publish(root, group, config, index, start, end, None)
        raise OSError('Interrupted before group checkpoint')

    monkeypatch.setattr(groups, '_publish', interrupt_after_legacy_publication)
    body = group_message(str(uuid.uuid4()), 0, 0, bytes(31 * 32000))
    with pytest.raises(OSError):
        accept_part(body, tmp_path)
    meta, = list((tmp_path / 'listen-captures').glob('*/metadata.json'))
    before = meta.read_bytes()
    assert 'speech_end_sample' not in json.loads(before)['conversation_group']
    monkeypatch.setattr(groups, '_publish', publish)
    assert accept_part(body, tmp_path)['stored'] is True
    assert meta.read_bytes() == before


def test_onset_preroll_survives_many_short_reconnect_parts(tmp_path, monkeypatch):
    from utils import local_conversation_groups as groups

    monkeypatch.setattr(groups.SpeechDetector, 'runs', lambda _s, pcm: [(0, len(pcm)//2)] if pcm[0] else [])
    recording = str(uuid.uuid4())
    for i in range(8):
        data = bytes([int(i == 7), 0]) * 640
        accept_part(group_message(recording, i, i*640, data), tmp_path)
    accept_part(group_message(recording, 8, 0, finish=True), tmp_path)
    meta, = list((tmp_path/'listen-captures').glob('*/metadata.json'))
    data = json.loads(meta.read_text())
    assert data['conversation_group']['start_sample'] == 7*640 - 3200
    assert data['decoded_pcm_bytes'] == (3200+640)*2
    assert data['frames_received'] is None and data['encoded_bytes'] is None

def test_long_conversation_writes_rf64_with_64bit_sample_count(tmp_path):
    from utils.local_conversation_groups import _conversation_wav

    audio = tmp_path / 'audio.wav'
    frames = (1 << 31) + 16000
    with _conversation_wav(audio, frames) as output:
        header_size = output.tell()
        output.seek(2 * (frames - 1), 1)
        output.write(b'\x23\x01')
    assert audio.stat().st_size == 2 * frames + header_size
    with audio.open('rb') as source:
        assert source.read(16) == b'RF64\xff\xff\xff\xffWAVEds64'
        chunk_size, riff_size, data_size, samples, table = struct.unpack('<IQQQI', source.read(32))
        assert (chunk_size, riff_size, data_size, samples, table) == (28, audio.stat().st_size - 8, 2 * frames, frames, 0)
    with pytest.raises(ValueError, match='Incomplete'):
        with _conversation_wav(tmp_path / 'incomplete.wav', frames) as output:
            output.write(b'\x00\x00')
