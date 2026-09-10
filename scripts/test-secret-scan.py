"""Exercise the real scanner's exact-value/path exception; use synthetic canaries only."""

import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile


def main():
    scanner = str(Path(sys.argv[1]).resolve())
    config = Path(__file__).resolve().parents[1] / '.gitleaks.toml'
    fixture = 'synthetic-' + 'replacement-123456'
    allowed_path = 'scripts/dev-harness/tests/test_local_mac.py'
    cases = [
        ('reviewed fixture', allowed_path, fixture, False),
        ('different value in same file', allowed_path, secrets.token_urlsafe(32), True),
        ('same value in different file', 'unreviewed.py', fixture, True),
    ]
    for label, relative_path, value, should_detect in cases:
        with tempfile.TemporaryDirectory(prefix='omiloc-scanner-test-') as temporary:
            root = Path(temporary)
            source = root / 'input'
            file = source / relative_path
            file.parent.mkdir(parents=True)
            file.write_text('NGROK_AUTHTOKEN=' + value + '\n')
            report = root / 'report.json'
            result = subprocess.run(
                [scanner, 'dir', str(source), '--config', str(config), '--redact=100',
                 '--ignore-gitleaks-allow', '--max-decode-depth', '2',
                 '--report-format', 'json', '--report-path', str(report)],
                capture_output=True, timeout=30,
            )
            if result.returncode not in (0, 1) or not report.is_file():
                raise RuntimeError('Scanner failed; raw output suppressed')
            findings = json.loads(report.read_text())
            expected = 1 if should_detect else 0
            if (len(findings) != expected or result.returncode != expected
                    or any(item.get('RuleID') != 'generic-api-key' for item in findings)):
                raise AssertionError('Unexpected scanner result: ' + label)
            print('PASS:', label)


if __name__ == '__main__':
    main()
