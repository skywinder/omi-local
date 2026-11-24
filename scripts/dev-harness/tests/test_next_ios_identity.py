"""Exercise the install guard for the separate Omi Local Next bundle."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[3]
NEXT = ROOT / 'clients/next'
sys.path.insert(0, str(NEXT))
spec = importlib.util.spec_from_file_location('next_iphone', NEXT / 'iphone.py')
iphone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iphone)
sys.path.remove(str(NEXT))


def package(tmp_path, bundle):
    app = tmp_path / 'Runner.app'
    app.mkdir()
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleName': iphone.NAME, 'CFBundleDisplayName': iphone.NAME,
        'CFBundleExecutable': 'Runner', 'CFBundleVersion': '1', 'CFBundlePackageType': 'APPL',
        'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
    }))
    return app


def test_reject_previous_app_before_inspecting_signature(tmp_path):
    with pytest.raises(ValueError, match='identity'):
        iphone.attest(package(tmp_path, 'org.example.legacy'), simulator=True)


@pytest.mark.skipif(sys.platform != 'darwin', reason='macOS signing tools')
def test_signed_simulator_artifact_and_sealed_content(tmp_path):
    app = package(tmp_path, iphone.BUNDLE)
    shutil.copyfile('/usr/bin/true', app / 'Runner')
    (app / 'Runner').chmod(0o755)
    asset = app / 'Note.txt'
    asset.write_text('fixture')
    subprocess.run(['codesign', '--force', '--sign', '-', app], check=True, capture_output=True)
    proof = iphone.attest(app, simulator=True)
    assert proof['bundle'] == 'org.omilocal.next'
    assert proof['signature'] == 'passed'
    asset.write_text('modified')
    with pytest.raises(ValueError, match='codesign'):
        iphone.attest(app, simulator=True)
