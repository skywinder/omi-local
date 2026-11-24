"""Configure a materialized upstream iOS Runner for the Omi Local Next client."""
import argparse
import json
import plistlib
import shutil
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET


HERE = Path(__file__).resolve().parent
BUNDLE = 'org.omilocal.next'
NAME = 'Omi Local Next'
CONFIGS = {'Debug-dev', 'Profile-dev', 'Release-dev'}


def prepare_project(project_file):
    project = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', project_file]))
    objects = project['objects']
    root = objects[project['rootObject']]
    runner_id, = [ref for ref in root['targets'] if objects[ref].get('name') == 'Runner']
    runner = objects[runner_id]
    root['targets'] = [runner_id]
    root['packageReferences'] = []
    root['attributes'].pop('TargetAttributes', None)
    runner['dependencies'] = []
    runner['packageProductDependencies'] = []

    # Keep the donor Flutter build, resources and pod integration. Only selected
    # native sources enter this binary. The archived upstream sources stay on disk.
    files = {
        'PBXSourcesBuildPhase': {'AppDelegate.swift'},
        'PBXResourcesBuildPhase': {'Assets.xcassets', 'Main.storyboard', 'LaunchScreen.storyboard'},
        'PBXFrameworksBuildPhase': {'Pods_Runner.framework'},
    }
    scripts = {'Run Script', 'Thin Binary'}
    kept = []
    for ref in runner['buildPhases']:
        phase = objects[ref]
        kind = phase['isa']
        if kind in files:
            allowed = files[kind]
            selected = []
            names = set()
            for build_file in phase['files']:
                file = objects.get(objects[build_file].get('fileRef'), {})
                name = file.get('name') or file.get('path')
                if name in allowed:
                    selected.append(build_file)
                    names.add(name)
            if names != allowed:
                raise ValueError(f'Upstream Runner membership changed in {kind}: {names}')
            phase['files'] = selected
        elif kind != 'PBXShellScriptBuildPhase' or phase.get('name') not in scripts:
            # pod install generates its own phases for the selected plugins.
            continue
        kept.append(ref)
    runner['buildPhases'] = kept
    for owner in (root, runner):
        config_list = objects[owner['buildConfigurationList']]
        kept_configs = [ref for ref in config_list['buildConfigurations'] if objects[ref]['name'] in CONFIGS]
        if {objects[ref]['name'] for ref in kept_configs} != CONFIGS:
            raise ValueError('Expected three dev build configurations')
        config_list['buildConfigurations'] = kept_configs
        config_list['defaultConfigurationName'] = 'Release-dev'
        for ref in kept_configs:
            settings = objects[ref]['buildSettings']
            # The simulator artifact runs on the host. Current Xcode lipo rejects
            # Flutter 3.44's multi-arch verification when given a generic simulator.
            settings['ARCHS[sdk=iphonesimulator*]'] = '$(NATIVE_ARCH_ACTUAL)'
            for key in list(settings):
                if key.startswith(('DEVELOPMENT_TEAM', 'CODE_SIGN_ENTITLEMENTS', 'PROVISIONING_PROFILE',
                                   'SWIFT_OBJC_BRIDGING_HEADER')):
                    del settings[key]
            if owner is runner:
                settings.pop('ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES', None)
                settings.update({
                    'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE, 'APP_BUNDLE_IDENTIFIER': BUNDLE,
                    'BUNDLE_DISPLAY_NAME': NAME, 'BUNDLE_NAME': NAME, 'INFOPLIST_KEY_CFBundleDisplayName': NAME,
                    'INFOPLIST_FILE': 'Runner/Info.plist', 'CODE_SIGN_STYLE': 'Automatic',
                    'ASSETCATALOG_COMPILER_APPICON_NAME': 'devAppIcon',
                    'DEVELOPMENT_TEAM': '$(OMI_APPLE_TEAM_ID)',
                    'SWIFT_OBJC_BRIDGING_HEADER': '', 'CODE_SIGN_ENTITLEMENTS': '',
                    'FLUTTER_TARGET': 'lib/main_local_next.dart',
                })
    project_file.write_bytes(plistlib.dumps(project, sort_keys=False))


def prepare_info(runner):
    # Flutter checks Runner/Info.plist for watch companionship even when Xcode's
    # INFOPLIST_FILE points elsewhere. Keep one manifest in this prepared Runner.
    original = plistlib.loads((runner / 'Info.plist').read_bytes())
    keys = {'CFBundleDevelopmentRegion', 'CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleInfoDictionaryVersion',
            'CFBundleName', 'CFBundleDisplayName', 'CFBundlePackageType', 'CFBundleShortVersionString',
            'CFBundleVersion', 'LSRequiresIPhoneOS', 'UIApplicationSceneManifest', 'UIMainStoryboardFile',
            'UISupportedInterfaceOrientations', 'UISupportedInterfaceOrientations~ipad',
            'CADisableMinimumFrameDurationOnPhone', 'UIApplicationSupportsIndirectInputEvents'}
    info = {key: val for key, val in original.items() if key in keys}
    scene, = info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication']
    scene['UISceneDelegateClassName'] = '$(PRODUCT_MODULE_NAME).NextSceneDelegate'
    info.update({
        'CFBundleDisplayName': NAME, 'CFBundleName': NAME, 'UILaunchStoryboardName': 'LaunchScreen',
        'NSMicrophoneUsageDescription': 'Record audio to your paired Omi Local server.',
        'UIBackgroundModes': ['audio'],
        'NSLocalNetworkUsageDescription': 'Omi Local Next connects to your paired recording server.',
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True, 'NSExceptionDomains': {
            '100.64.0.0/10': {'NSExceptionAllowsInsecureHTTPLoads': True},
        }},
    })
    (runner / 'Info.plist').write_bytes(plistlib.dumps(info))


def prepare_scheme(path):
    scheme = ET.parse(path)
    build = scheme.find('BuildAction')
    runner = scheme.find('LaunchAction/BuildableProductRunnable/BuildableReference')
    if build is None or runner is None or runner.get('BlueprintName') != 'Runner':
        raise ValueError('Expected a dev scheme that launches Runner')
    # CocoaPods builds the engine in Runner's normal build phase. The donor's
    # SPM-only preaction cannot substitute for an actual Runner build action.
    build[:] = []
    entries = ET.SubElement(build, 'BuildActionEntries')
    entry = ET.SubElement(entries, 'BuildActionEntry', {
        key: 'YES' for key in ('buildForTesting', 'buildForRunning', 'buildForProfiling',
                              'buildForArchiving', 'buildForAnalyzing')})
    ET.SubElement(entry, 'BuildableReference', runner.attrib)
    scheme.find('ProfileAction').set('buildConfiguration', 'Profile-dev')
    scheme.write(path, encoding='utf-8', xml_declaration=True)


def prepare(app):
    if (app.parent / 'upstream-revision').read_text().strip() != json.loads((HERE / 'upstream.json').read_text())['commit']:
        raise ValueError('Prepare the pinned disposable app with prepare.py')
    ios = app / 'ios'
    runner = ios / 'Runner'
    prepare_project(ios / 'Runner.xcodeproj' / 'project.pbxproj')
    prepare_info(runner)
    shutil.copyfile(HERE / 'ios' / 'AppDelegate.swift', runner / 'AppDelegate.swift')
    shutil.copyfile(HERE / 'ios' / 'Podfile', ios / 'Podfile')
    # Runner is the only target in this disposable project.
    for scheme in (ios / 'Runner.xcodeproj' / 'xcshareddata' / 'xcschemes').glob('*.xcscheme'):
        if scheme.name != 'dev.xcscheme':
            scheme.unlink()
        else:
            prepare_scheme(scheme)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    prepare(parser.parse_args().app.resolve())
