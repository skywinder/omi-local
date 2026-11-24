"""Prepare the pinned Omi Flutter tree in a disposable, revision-specific directory."""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from live_labels import prepare_live_labels
from presentation import apply_presentation

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PIN = json.loads((HERE / 'upstream.json').read_text())


def extract(repo, directory, subtree):
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['git', '-C', repo, 'archive', '--format=tar', PIN['commit'], subtree], stdout=archive, check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as tree:
            for member in tree:
                path = Path(member.name)
                if path.is_absolute() or path.parts[:1] != ('app',) or '..' in path.parts:
                    raise ValueError(f'Unexpected upstream path {path}')
                if not member.isdir() and not member.isfile():
                    raise ValueError(f'Unsupported upstream entry {path}')
                tree.extract(member, directory, set_attrs=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path, help='local clone of BasedHardware/omi containing the pinned commit')
    parser.add_argument('--source-only', action='store_true', help='prepare Flutter source without iOS settings')
    args = parser.parse_args()
    revision = PIN['commit']
    if not re.fullmatch('[a-f0-9]{40}', revision):
        parser.error('upstream.json must pin a full Git commit')
    cache = ROOT / '.local' / 'clients' / 'next'
    cache.mkdir(parents=True, exist_ok=True)
    build = cache / revision
    if not build.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temp:
            staging = Path(temp) / 'tree'
            staging.mkdir()
            extract(args.repository.resolve(), staging, 'app')
            (staging / 'upstream-revision').write_text(revision + '\n')
            staging.rename(build)
    if (build / 'upstream-revision').read_text().strip() != revision:
        raise ValueError('Unexpected source directory')
    app = build / 'app'
    apply_presentation(args.repository, revision, app)
    if not args.source_only:
        # Restore tracked native inputs before applying the repeatable identity overlay.
        extract(args.repository.resolve(), build, 'app/ios')
        subprocess.run([sys.executable, HERE / 'ios_prepare.py', app], check=True)
    shutil.copytree(HERE / 'overlay', app, dirs_exist_ok=True)
    prepare_live_labels(ROOT, app)
    for relative in (
        'lib/services/capture/local_audio_journal.dart',
        'lib/services/capture/local_opus_preroll.dart',
        'lib/services/capture/cv1_opus_frame_assembler.dart',
        'lib/services/local_runtime_status_model.dart',
    ):
        if subprocess.check_output(['git', '-C', args.repository, 'ls-tree', revision, 'app/' + str(relative)]):
            raise ValueError(f'Upstream now supplies {relative}; reconcile its implementation before updating')
        shutil.copy2(ROOT / 'app' / relative, app / relative)
    print(app)


if __name__ == '__main__':
    main()
