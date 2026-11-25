"""Build the isolated Omi Local Next Android debug APK from the pinned Flutter tree."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from cv1_protocol import cv1_feature_masks, cv1_uuids
from prepare import HERE, PIN

PLUGINS = {
    'audio_session', 'device_info_plus', 'flutter_secure_storage', 'flutter_sound', 'just_audio',
    'path_provider_android', 'permission_handler_android', 'quick_actions_android', 'share_plus', 'shared_preferences_android',
}


def prepare_native(app):
    android = app / 'android'
    settings = android / 'settings.gradle'
    settings.write_text(re.sub(
        r"^    id \"com\.google\.(?:gms|firebase)\.[^\n]+\n",
        '', settings.read_text(), flags=re.MULTILINE,
    ))
    # The donor's app build config, receiver declarations and resources refer to
    # native services that Next does not launch. Retain only Flutter's themes and icon.
    main = android / 'app/src/main'
    donor_source = (main / 'kotlin', main / 'java/com')
    donor_variants = (android / 'app/src' / name for name in ('dev', 'prod', 'debug', 'profile'))
    for path in (*donor_source, *donor_variants):
        if path.exists():
            shutil.rmtree(path)
    shutil.copyfile(HERE / 'android/app.gradle', android / 'app/build.gradle')
    shutil.copyfile(HERE / 'android/AndroidManifest.xml', main / 'AndroidManifest.xml')
    activity = main / 'kotlin/org/omilocal/next/MainActivity.kt'
    activity.parent.mkdir(parents=True, exist_ok=True)
    for source in ('MainActivity.kt', 'NextCV1.kt'):
        shutil.copyfile(HERE / 'android' / source, activity.parent / source)
    constants = [f'    val {name} = java.util.UUID.fromString("{value}")'
                 for name, value in cv1_uuids(app).items()]
    constants.extend(f'    const val {name} = {value}' for name, value in cv1_feature_masks(app).items())
    (activity.parent / 'Cv1Uuid.kt').write_text(
        'package org.omilocal.next\n\ninternal object Cv1Uuid {\n' + '\n'.join(constants) + '\n}\n'
    )

    # Keep the pinned Dart graph. Flutter's Gradle loader and embedding must see
    # the same reduced set of native plugins for this standalone build.
    dependencies = app / '.flutter-plugins-dependencies'
    doc = json.loads(dependencies.read_text())
    plugins = doc['plugins']['android']
    retained = [plugin for plugin in plugins if plugin['name'] in PLUGINS]
    if {plugin['name'] for plugin in retained} != PLUGINS:
        raise ValueError('Unexpected Android plugin graph for the pinned revision')
    if any(set(plugin.get('dependencies', ())) - PLUGINS for plugin in retained):
        raise ValueError('A selected plugin requires another Android plugin')
    doc['plugins']['android'] = retained
    dependencies.write_text(json.dumps(doc))
    registrant = main / 'java/io/flutter/plugins/GeneratedPluginRegistrant.java'
    source = registrant.read_text()
    seen = set()

    def keep(match):
        name = re.search(r'Error registering plugin ([a-z0-9_]+),', match[0])[1]
        if name not in PLUGINS:
            return ''
        seen.add(name)
        return match[0]

    source = re.sub(r'    try \{\n.*?    \}\n', keep, source, flags=re.DOTALL)
    if seen != PLUGINS:
        raise ValueError('Unexpected Flutter Android registrant')
    registrant.write_text(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path, help='local BasedHardware/omi clone')
    parser.add_argument('--offline', action='store_true', help='use the existing Gradle caches')
    args = parser.parse_args()
    flutter = Path(shutil.which('flutter') or 'flutter').resolve()
    version = json.loads(subprocess.check_output([flutter, '--version', '--machine']))
    if version['frameworkVersion'] != PIN['flutter']:
        raise ValueError('Use Flutter ' + PIN['flutter'])
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk or not Path(sdk).is_dir():
        raise ValueError('Set ANDROID_HOME to an installed Android SDK')
    app = Path(subprocess.check_output(
        [sys.executable, HERE / 'prepare.py', args.repository, '--android'], text=True,
    ).strip())
    subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=app, check=True)
    (app / 'android/local.properties').write_text(f'sdk.dir={sdk}\nflutter.sdk={flutter.parent.parent}\n')
    prepare_native(app)
    gradle = shutil.which('gradle') or str(app / 'android/gradlew')
    command = [gradle, ':app:assembleDebug', '-Ptarget=lib/main_local_next.dart',
               '-Ptarget-platform=android-arm64', '--console=plain']
    if args.offline:
        command.append('--offline')
    subprocess.run(command, cwd=app / 'android', check=True)
    apk = app / 'build/app/outputs/apk/debug/app-debug.apk'
    if not apk.is_file():
        raise ValueError('Android APK was not generated')
    print(apk)


if __name__ == '__main__':
    main()
