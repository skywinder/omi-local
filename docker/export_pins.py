"""Reuse runtime package versions with native Linux wheels on arm64 and amd64.

The upstream pylock contains only x86_64 wheel URLs. Do not feed those artifacts
into an arm64 build or resolve the loosely constrained requirements.txt afresh.
"""
import sys
import tomllib

with open(sys.argv[1], 'rb') as source:
    packages = tomllib.load(source)['packages']
for package in packages:
    marker = '; ' + package['marker'] if package.get('marker') else ''
    if vcs := package.get('vcs'):
        print(f"{package['name']} @ git+{vcs['url']}@{vcs['commit-id']}{marker}")
    else:
        print(f"{package['name']}=={package['version']}{marker}")
