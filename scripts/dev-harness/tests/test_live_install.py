"""Hermetic preparation contracts; native builds and model downloads are stubbed."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dev_harness import local_live_install as live, stt_install

REPO = Path(__file__).resolve().parents[3]


@pytest.fixture
def prepared(tmp_path):
    repo = tmp_path / 'project'
    for relative in [live.FIXTURE, live.MANIFEST, *(live.PACKAGE / name for name in live.BUILD_FILES)]:
        target = repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / relative, target)
    data = live.recipe(repo)
    model = b'synthetic model'
    data['assets'] = [{'path': 'models/parakeet-tdt-0.6b-v3/model.bin', 'url': 'https://example.invalid/model',
                       'size': len(model), 'sha256': hashlib.sha256(model).hexdigest()}]
    (repo / live.MANIFEST).write_text(json.dumps(data))
    root = live.runtime_root(repo)
    files = {live.BINARY: b'synthetic executable', live.BUNDLE + '/resource': b'synthetic resource',
             'models/parakeet-tdt-0.6b-v3/model.bin': model}
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    (root / live.BINARY).chmod(0o700)
    receipt = {'inputs': live.build_inputs(repo, 'synthetic toolchain'),
               'files': {name: stt_install.digest(root / name) for name in files if name.startswith('bin/')}}
    stt_install.atomic_json(root / 'build-receipt.json', receipt)
    stt_install.atomic_json(root / 'ready.json', {
        'revision': live.revision(repo), 'offline_speech_check': 'passed',
        'files': {name: [(root / name).stat().st_size, (root / name).stat().st_mtime_ns] for name in files},
    })
    return repo


def test_pinned_recipe_matches_package_and_synthetic_fixture():
    recipe = live.recipe(REPO)
    assert recipe['sdk_commit'] in (REPO / live.PACKAGE / 'Package.swift').read_text()
    pins = json.loads((REPO / live.PACKAGE / 'Package.resolved').read_text())['pins']
    assert pins == [{'identity': 'fluidaudio', 'kind': 'remoteSourceControl', 'location': recipe['sdk_url'],
                     'state': {'revision': recipe['sdk_commit']}}]
    assert len(recipe['assets']) == 21
    assert sum(asset['size'] for asset in recipe['assets']) == 483105645
    for asset in recipe['assets']:
        assert asset['url'].startswith(f"https://huggingface.co/{recipe['model']}/resolve/{recipe['model_revision']}/")
        assert len(asset['sha256']) == 64 and asset['path'].startswith('models/parakeet-tdt-0.6b-v3/')
    assert stt_install.digest(REPO / live.FIXTURE) == recipe['smoke_sha256']


def test_receipt_requires_all_models_native_resources_and_offline_smoke(prepared):
    root = live.runtime_root(prepared)
    assert live.installed(prepared) == (root / live.BINARY, root / live.MODEL_DIR)
    ready_path = root / 'ready.json'
    original = ready_path.read_text()
    for change in ('unproven', 'missing', 'version'):
        ready = json.loads(original)
        if change == 'unproven':
            ready['offline_speech_check'] = 'failed'
        elif change == 'missing':
            ready['files'].pop('models/parakeet-tdt-0.6b-v3/model.bin')
        else:
            ready['revision'] = 'old'
        ready_path.write_text(json.dumps(ready))
        with pytest.raises(live.LiveInstallError):
            live.installed(prepared)


def test_installed_supplies_the_sdk_repo_named_directory(prepared):
    # Pinned AsrModels.load(from:) reconstructs parent / version.repo.folderName.
    # Therefore this basename is part of the public SDK loading contract.
    _, models = live.installed(prepared)
    assert models.name == 'parakeet-tdt-0.6b-v3'
    assert (models / 'model.bin').is_file()


@pytest.mark.parametrize('name', ['models/parakeet-tdt-0.6b-v3/model.bin', live.BINARY, live.BUNDLE + '/resource'])
def test_changed_installed_file_invalidates_readiness(prepared, name):
    path = live.runtime_root(prepared) / name
    path.write_bytes(b'changed')
    with pytest.raises(live.LiveInstallError):
        live.installed(prepared)


def test_binary_hash_detects_same_size_and_restored_timestamp(prepared):
    path = live.runtime_root(prepared) / live.BINARY
    stamp = path.stat()
    path.write_bytes(b'x' * stamp.st_size)
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    with pytest.raises(live.LiveInstallError):
        live.installed(prepared)


def test_model_directory_symlink_rejected_without_following(prepared, tmp_path):
    root = live.runtime_root(prepared)
    shutil.move(root / live.MODEL_DIR, tmp_path / 'outside')
    (root / live.MODEL_DIR).symlink_to(tmp_path / 'outside', target_is_directory=True)
    with pytest.raises(live.LiveInstallError):
        live.installed(prepared)


def test_old_swift_stops_before_any_installation(tmp_path, monkeypatch):
    monkeypatch.setattr(live.platform, 'system', lambda: 'Darwin')
    monkeypatch.setattr(live.platform, 'machine', lambda: 'arm64')
    monkeypatch.setattr(live.platform, 'mac_ver', lambda: ('14.0', '', ''))
    monkeypatch.setattr(live.shutil, 'which', lambda _: '/fixture/tool')
    monkeypatch.setattr(live, 'runtime_root', lambda _: tmp_path / 'uncreated')
    monkeypatch.setattr(live, 'safe_path', lambda *_: None)
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        return SimpleNamespace(returncode=0, stdout='Apple Swift version 5.10')

    monkeypatch.setattr(live.subprocess, 'run', run)
    with pytest.raises(live.LiveInstallError, match='6.0'):
        live.install(REPO)
    assert commands == [['xcrun', 'swift', '--version']]
    assert not (tmp_path / 'uncreated').exists()


def test_failed_preflight_never_downloads_or_builds(prepared, monkeypatch):
    before = (live.runtime_root(prepared) / 'ready.json').read_bytes()

    def fail(_):
        raise live.LiveInstallError('synthetic SDK unavailable')

    monkeypatch.setattr(live, 'preflight', fail)
    monkeypatch.setattr(live, 'build', lambda *_: pytest.fail('build before preflight'))
    monkeypatch.setattr(stt_install, 'download', lambda *_: pytest.fail('download before preflight'))
    with pytest.raises(live.LiveInstallError, match='SDK'):
        live.install(prepared)
    assert (live.runtime_root(prepared) / 'ready.json').read_bytes() == before


def test_install_reuses_exact_binary_and_existing_model_without_network(prepared, monkeypatch):
    root = live.runtime_root(prepared)
    binary_before = (root / live.BINARY).stat()
    monkeypatch.setattr(live, 'preflight', lambda _: 'synthetic toolchain')
    monkeypatch.setattr(live, 'build', lambda *_: pytest.fail('unchanged build must be reused'))
    monkeypatch.setattr(stt_install.urllib.request, 'urlopen', lambda *_a, **_k: pytest.fail('model already verified'))
    checks = []
    monkeypatch.setattr(live, 'smoke', lambda *args: checks.append(args))
    live.install(prepared)
    assert checks == [(prepared, root / live.BINARY, root / live.MODEL_DIR)]
    assert (root / live.BINARY).stat().st_mtime_ns == binary_before.st_mtime_ns
    assert live.installed(prepared) == (root / live.BINARY, root / live.MODEL_DIR)


def test_changed_worker_builds_pinned_package_and_copies_native_resources(prepared, monkeypatch):
    root = live.runtime_root(prepared)
    worker = prepared / live.PACKAGE / 'ParakeetWorker.swift'
    worker.write_text(worker.read_text() + '\n// synthetic changed input\n')
    monkeypatch.setattr(live, 'preflight', lambda _: 'synthetic toolchain')
    monkeypatch.setattr(live, 'smoke', lambda *_: None)
    monkeypatch.setattr(stt_install.urllib.request, 'urlopen', lambda *_a, **_k: pytest.fail('model already verified'))
    commands = []

    def compile(command, **kwargs):
        commands.append(command)
        source = kwargs['cwd']
        assert (source / 'ParakeetWorker.swift').read_bytes() == worker.read_bytes()
        assert (source / 'Package.resolved').read_bytes() == (prepared / live.PACKAGE / 'Package.resolved').read_bytes()
        output = source / '.build/release'
        bundle = output / 'FluidAudio_FluidAudio.bundle'
        bundle.mkdir(parents=True)
        (bundle / 'resource').write_bytes(b'rebuilt resource')
        (output / 'ParakeetWorker').write_bytes(b'rebuilt executable')
        (output / 'ParakeetWorker').chmod(0o700)
        assert kwargs['pass_fds']
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(live.subprocess, 'run', compile)
    live.install(prepared)
    assert commands == [['xcrun', 'swift', 'build', '-c', 'release', '--product', 'ParakeetWorker',
                         '--disable-automatic-resolution', '-j', '2']]
    assert (root / live.BINARY).read_bytes() == b'rebuilt executable'
    assert (root / live.BUNDLE / 'resource').read_bytes() == b'rebuilt resource'
    assert live.installed(prepared) == (root / live.BINARY, root / live.MODEL_DIR)


def test_failed_smoke_clears_readiness_but_preserves_build_and_models(prepared, monkeypatch):
    root = live.runtime_root(prepared)
    monkeypatch.setattr(live, 'preflight', lambda _: 'synthetic toolchain')

    def fail(*_):
        raise live.LiveInstallError('synthetic model failure')

    monkeypatch.setattr(live, 'smoke', fail)
    with pytest.raises(live.LiveInstallError, match='model failure'):
        live.install(prepared)
    assert not (root / 'ready.json').exists()
    assert (root / live.BINARY).is_file() and (root / 'models/parakeet-tdt-0.6b-v3/model.bin').is_file()


@pytest.mark.parametrize('mode', ['passed', 'no_text', 'model_error', 'stalled'])
def test_smoke_exercises_real_child_protocol_and_reaps_it(prepared, tmp_path, monkeypatch, mode):
    worker = tmp_path / 'synthetic_worker.py'
    worker.write_text('''import json, struct, sys, time
def emit(message):
    print(json.dumps(message), flush=True)
mode=sys.argv[1]
emit({'type': 'error' if mode == 'model_error' else 'model_ready'})
if mode == 'model_error':
    raise SystemExit(1)
while True:
    header=sys.stdin.buffer.read(4)
    if not header:
        break
    count=struct.unpack('!I', header)[0]
    frame=sys.stdin.buffer.read(count)
    if frame[0] == 1:
        emit({'type':'started'})
        if mode == 'stalled':
            time.sleep(30)
    elif frame[0] == 2:
        assert len(frame) > 1 and len(frame) % 2 == 1
    elif frame[0] == 3:
        emit({'type':'snapshot', 'text':'проверка погода текст' if mode == 'passed' else ''})
        emit({'type':'finished'})
''')
    root = live.runtime_root(prepared)
    calls = []
    monkeypatch.setattr(live, 'offline', lambda command: calls.append(command) or [sys.executable, str(worker), mode])
    processes = []
    original = subprocess.Popen

    def popen(*args, **kwargs):
        child = original(*args, **kwargs)
        processes.append(child)
        return child

    monkeypatch.setattr(live.subprocess, 'Popen', popen)
    if mode == 'passed':
        live.smoke(prepared, root / live.BINARY, root / live.MODEL_DIR, timeout=2)
    else:
        with pytest.raises(live.LiveInstallError):
            live.smoke(prepared, root / live.BINARY, root / live.MODEL_DIR, timeout=.3)
    assert calls == [[str(root / live.BINARY), str(root / live.MODEL_DIR)]]
    assert len(processes) == 1 and processes[0].poll() is not None


def test_network_deny_wrapper_is_mandatory(monkeypatch):
    monkeypatch.setattr(live.shutil, 'which', lambda _: None)
    with pytest.raises(live.LiveInstallError):
        live.offline(['synthetic-worker'])
    monkeypatch.setattr(live.shutil, 'which', lambda _: '/usr/bin/sandbox-exec')
    assert live.offline(['synthetic-worker']) == [
        '/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)', 'synthetic-worker']
