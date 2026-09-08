import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import zipfile
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import stt_install as install
from dev_harness import local_stt


def asset(blob, path='model.bin'):
    return {'path': path, 'url': 'https://example.invalid/model', 'size': len(blob),
            'sha256': hashlib.sha256(blob).hexdigest()}


class Response(io.BytesIO):
    def __init__(self, blob, *, status=200, headers=None):
        super().__init__(blob)
        self.status = status
        self.headers = headers or {}


@pytest.mark.parametrize('range_supported', [True, False])
def test_download_resumes_or_restarts_and_checks_hash(tmp_path, monkeypatch, range_supported):
    blob = b'first half, second half'
    partial = tmp_path / 'model.bin.part'
    partial.write_bytes(blob[:10])
    requests = []
    def respond(request, **kwargs):
        requests.append(request)
        return Response(blob[10:] if range_supported else blob, status=206 if range_supported else 200,
                        headers={'Content-Range': f'bytes 10-{len(blob)-1}/{len(blob)}'})
    monkeypatch.setattr(install.urllib.request, 'urlopen', respond)
    install.download(asset(blob), tmp_path)
    assert requests[0].get_header('Range') == f'bytes=10-{len(blob)-1}'
    assert (tmp_path / 'model.bin').read_bytes() == blob
    assert not partial.exists()
    install.download(asset(blob), tmp_path)
    assert len(requests) == 1


def test_interrupted_download_preserves_progress_for_retry(tmp_path, monkeypatch):
    blob = b'first-second'
    class Interrupted(Response):
        def read(self, size=-1):
            if self.tell():
                raise OSError('fixture connection closed')
            return super().read(6)
    monkeypatch.setattr(install.urllib.request, 'urlopen', lambda *a, **k: Interrupted(blob))
    with pytest.raises(OSError):
        install.download(asset(blob), tmp_path)
    assert (tmp_path / 'model.bin.part').read_bytes() == blob[:6]
    assert not (tmp_path / 'model.bin').exists()
    monkeypatch.setattr(install.urllib.request, 'urlopen', lambda *a, **k:
                        Response(blob[6:], status=206, headers={'Content-Range': 'bytes 6-11/12'}))
    install.download(asset(blob), tmp_path)
    assert (tmp_path / 'model.bin').read_bytes() == blob


def test_bad_download_never_becomes_a_model(tmp_path, monkeypatch):
    monkeypatch.setattr(install.urllib.request, 'urlopen', lambda *a, **k: Response(b'corrupt'))
    with pytest.raises(install.InstallError, match='сумма'):
        install.download(asset(b'correct'), tmp_path)
    assert not list(tmp_path.iterdir())


def test_short_http_response_is_completed_instead_of_discarded(tmp_path, monkeypatch):
    blob = b'first-second'
    offsets = []
    def respond(request, **kwargs):
        offset = int(request.get_header('Range').split('=')[1].split('-')[0])
        offsets.append(offset)
        piece = blob[offset:offset + 6]
        return Response(piece, status=206,
                        headers={'Content-Range': f'bytes {offset}-{offset+len(piece)-1}/{len(blob)}'})
    monkeypatch.setattr(install.urllib.request, 'urlopen', respond)
    install.download(asset(blob), tmp_path)
    assert offsets == [0, 6]
    assert (tmp_path / 'model.bin').read_bytes() == blob


def test_wrong_range_at_start_is_rejected_before_writing(tmp_path, monkeypatch):
    monkeypatch.setattr(install.urllib.request, 'urlopen', lambda *a, **k:
                        Response(b'wrong', status=206, headers={'Content-Range': 'bytes 5-9/10'}))
    with pytest.raises(install.InstallError, match='диапазон'):
        install.download(asset(b'0123456789'), tmp_path)
    assert not list(tmp_path.iterdir())


def fixture_source(tmp_path):
    source = tmp_path / 'source'
    for name in install.INPUTS:
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('fixture')
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name in ('collocations.tab', 'sent_starters.txt', 'abbrev_types.txt', 'ortho_context.tab'):
            archive.writestr('punkt_tab/russian/' + name, 'fixture')
    blob = buffer.getvalue()
    data = {'python': '3.12.14', 'macos_min': 14, 'patches': {}, 'assets': [asset(blob, 'nltk/punkt_tab.zip')],
            'smoke': {'path': 'fixtures/speech-check.wav', 'sha256': install.digest(source / 'fixtures/speech-check.wav')}}
    (source / 'whisperx-models.json').write_text(json.dumps(data))
    return source, blob


@pytest.mark.parametrize('failure', ['sync', 'download', 'model-check'])
def test_install_retries_each_incomplete_stage_and_attests_only_success(tmp_path, monkeypatch, failure):
    source, blob = fixture_source(tmp_path)
    root = tmp_path / 'installation'
    events = []
    failing = True
    monkeypatch.setattr(install.platform, 'system', lambda: 'Darwin')
    monkeypatch.setattr(install.platform, 'machine', lambda: 'arm64')
    monkeypatch.setattr(install.platform, 'mac_ver', lambda: ('14.0', (), ''))
    monkeypatch.setattr(install.shutil, 'which', lambda name: '/fixture/' + name)
    monkeypatch.setattr(install.shutil, 'disk_usage', lambda _: SimpleNamespace(free=20 * 1024**3))
    monkeypatch.setattr(install, 'apply_patch', lambda *a: events.append('patch'))
    monkeypatch.setattr(install.subprocess, 'check_output', lambda *a, **k: '/fixture/ffmpeg@7\n')
    def run(command, **kwargs):
        events.append(tuple(command))
        if command[:2] == ['uv', 'venv']:
            python = Path(command[-1]) / 'bin/python'
            python.parent.mkdir(parents=True, exist_ok=True)
            python.write_text('fixture')
        bad = failing and ((failure == 'sync' and command[:3] == ['uv', 'pip', 'sync'])
                           or (failure == 'model-check' and '--check' in command))
        if bad:
            raise subprocess.CalledProcessError(9, command)
        return SimpleNamespace(returncode=0, stdout='/fixture/ffmpeg@7\n')
    monkeypatch.setattr(install.subprocess, 'run', run)
    def respond(*a, **k):
        if failing and failure == 'download':
            raise OSError('fixture network failure')
        return Response(blob)
    monkeypatch.setattr(install.urllib.request, 'urlopen', respond)
    with pytest.raises((OSError, subprocess.CalledProcessError)):
        install.install(root, source)
    assert not (root / 'ready.json').exists()
    failing = False
    install.install(root, source)
    assert install.installed(root, source) is not None
    assert ('uv', 'python', 'install', '--no-bin', '3.12.14') in events
    assert '--reinstall' in next(e for e in events if isinstance(e, tuple) and e[:3] == ('uv', 'pip', 'sync'))
    before = len(events)
    install.install(root, source)
    assert all(event[0] != 'uv' for event in events[before:])
    # Missing assets invalidate a completed installation, including NLTK's unpacked files.
    (root / 'assets/nltk/tokenizers/punkt_tab/russian/abbrev_types.txt').unlink()
    assert install.installed(root, source) is None
    install.install(root, source)
    assert install.installed(root, source) is not None
    (source / 'requirements-whisperx-macos.txt').write_text('changed dependency lock')
    assert install.installed(root, source) is None


def test_patch_is_idempotent_and_does_not_edit_shared_source_in_place(tmp_path, monkeypatch):
    site, source = tmp_path / 'site', tmp_path / 'source'
    site.mkdir()
    source.mkdir()
    target = site / 'whisperx/asr.py'
    target.parent.mkdir()
    old, new = b'value = 1\n', b'value = 2\n'
    target.write_bytes(old)
    shared = tmp_path / 'cached-source.py'
    shared.hardlink_to(target)
    (source / 'whisperx-local.patch').write_text(
        '--- a/whisperx/asr.py\n+++ b/whisperx/asr.py\n@@ -1 +1 @@\n-value = 1\n+value = 2\n')
    data = {'patches': {'whisperx/asr.py': {'original': hashlib.sha256(old).hexdigest(),
                                         'patched': hashlib.sha256(new).hexdigest()}}}
    monkeypatch.setattr(install.subprocess, 'check_output', lambda *a, **k: str(site))
    with (tmp_path / 'patch.log').open('w') as log:
        install.apply_patch(Path(sys.executable), data, {}, log, source)
        install.apply_patch(Path(sys.executable), data, {}, log, source)
    assert target.read_bytes() == new
    assert shared.read_bytes() == old


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('sandbox-exec'), reason='macOS native sandbox')
def test_real_sandbox_keeps_ffmpeg_path_and_denies_network(tmp_path):
    env = {**os.environ, 'DYLD_LIBRARY_PATH': str(tmp_path)}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        probe = '''
import json, os, socket, sys
connected = False
denied = False
try:
    with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2):
        connected = True
except PermissionError:
    denied = True
print(json.dumps([connected, denied, os.environ.get('DYLD_LIBRARY_PATH')]))
'''
        command = [sys.executable, '-c', probe, str(listener.getsockname()[1])]
        direct = subprocess.run(command, env=env, capture_output=True, text=True, check=True, timeout=10)
        assert json.loads(direct.stdout)[0] is True  # Positive control for the observer.
        guarded = subprocess.run(install.offline_command(command, env), env=env,
                                 capture_output=True, text=True, check=True, timeout=10)
        assert json.loads(guarded.stdout) == [False, True, str(tmp_path)]


def test_managed_runtime_is_selected_without_changing_an_explicit_engine(tmp_path, monkeypatch):
    root = tmp_path / '.local/stt'
    root.mkdir(parents=True)
    (root / 'ready.json').write_text('{}')
    state = tmp_path / 'state'
    state.mkdir()
    cfg = SimpleNamespace(repo_root=tmp_path, layout=SimpleNamespace(state_root=state))
    monkeypatch.setattr(install, 'installed', lambda _: root / 'venv/bin/python')
    monkeypatch.setattr(install, 'fingerprint', lambda: 'fixture-revision')
    engine = local_stt.EngineConfig.load(cfg)
    assert engine.assets_path == str(root / 'assets') and engine.diarization_model == 'none'
    assert engine.profile()['runtime_revision'] == 'fixture-revision'
    (state / 'stt-engine.json').write_text(json.dumps({'python': '/custom/python'}))
    assert local_stt.EngineConfig.load(cfg).python == '/custom/python'
    assert not local_stt.EngineConfig.load(cfg).assets_path
    for settings in ({'model': 'small', 'diarization_model': 'none'},
                     {'diarization_model': 'pyannote/speaker-diarization-community-1'},
                     {'model': 'large-v3-turbo'}):
        (state / 'stt-engine.json').write_text(json.dumps(settings))
        assert not local_stt.EngineConfig.load(cfg).assets_path
    (state / 'stt-engine.json').unlink()
    monkeypatch.setattr(install, 'installed', lambda _: None)
    with pytest.raises(local_stt.TranscriptionError, match='incomplete'):
        local_stt.EngineConfig.load(cfg)


def test_engine_without_repo_does_not_pick_up_an_installation_from_the_current_directory(tmp_path, monkeypatch):
    (tmp_path / '.local/stt').mkdir(parents=True)
    monkeypatch.chdir(tmp_path)
    cfg = SimpleNamespace(layout=SimpleNamespace(state_root=tmp_path / 'state'))
    monkeypatch.setattr(install, 'installed', lambda _: pytest.fail('Unrelated runtime was inspected'))
    assert not local_stt.EngineConfig.load(cfg).assets_path


def test_speech_check_requires_recognized_words_and_real_timestamps():
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dev_harness'))
    from local_whisperx import validate_smoke
    expected = ['проверка', 'записи', 'сегодня', 'текст']
    raw = {'segments': [{'text': 'Проверка записи сегодня. Текст.',
                         'words': [{'word': word, 'start': i, 'end': i + 0.5} for i, word in enumerate(expected)]}]}
    validate_smoke(raw, expected, 5)
    raw['segments'][0]['words'][0]['end'] = 8
    with pytest.raises(ValueError):
        validate_smoke(raw, expected, 5)
    raw['segments'][0]['text'] = 'неправильный результат'
    with pytest.raises(ValueError):
        validate_smoke(raw, expected, 10)


def test_readiness_rejects_changed_or_missing_installed_dependencies(tmp_path, monkeypatch):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dev_harness'))
    from local_whisperx import verify_runtime, metadata
    (tmp_path / 'requirements-whisperx-macos.txt').write_text('whisperx==3.8.6\n')
    data = {'python': '.'.join(map(str, sys.version_info[:3]))}
    monkeypatch.setattr(metadata, 'version', lambda _: '3.8.6')
    verify_runtime(data, tmp_path)
    monkeypatch.setattr(metadata, 'version', lambda _: '3.8.7')
    with pytest.raises(ValueError, match='Зависимости'):
        verify_runtime(data, tmp_path)
    def missing(_):
        raise metadata.PackageNotFoundError('whisperx')
    monkeypatch.setattr(metadata, 'version', missing)
    with pytest.raises(ValueError, match='Зависимости'):
        verify_runtime(data, tmp_path)
    with pytest.raises(ValueError, match='Python'):
        verify_runtime({'python': '0.0.0'}, tmp_path)


def test_managed_transcription_uses_verified_wrapper_and_returns_speakers(tmp_path, monkeypatch):
    import wave
    audio = tmp_path / 'input.wav'
    with wave.open(str(audio), 'wb') as stream:
        stream.setparams((1, 2, 16000, 0, 'NONE', ''))
        stream.writeframes(b'\x00\x00' * 16000)
    engine = local_stt.EngineConfig(python='/fixture/python', assets_path=str(tmp_path / 'model assets'),
                                   runtime_revision='fixture', diarization_model='none')
    monkeypatch.setattr(local_stt, 'check_model', lambda _: Path(engine.python))
    monkeypatch.setattr(local_stt.shutil, 'which', lambda _: None)
    monkeypatch.setattr(install, 'offline_command', lambda command, env: ['network-guard', *command])
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        folder = Path(command[command.index('--output_dir') + 1])
        (folder / 'audio.json').write_text(json.dumps({'segments': [{'text': 'Fixture', 'words': []}]}))
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(local_stt.subprocess, 'run', run)
    result = local_stt.run_whisperx(engine, audio, tmp_path, local_stt.inspect_audio(audio))
    assert calls[0][0] == 'network-guard'
    assert Path(calls[0][2]).name == 'local_whisperx.py'
    assert calls[0][calls[0].index('--assets') + 1] == engine.assets_path
    assert result['segments'][0]['speaker'] == 'SPEAKER_00'
