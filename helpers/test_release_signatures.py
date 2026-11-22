"""Production verification must fail closed when entitlement inspection fails."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SignatureVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.app = self.folder / 'HyperMug.app'
        self.app.mkdir()
        commands = self.folder / 'bin'
        commands.mkdir()
        codesign = commands / 'codesign'
        codesign.write_text('''#!/usr/bin/env bash
set -eu
case "$1" in
  -dv) printf 'TeamIdentifier=TEAM123456\nCodeDirectory flags=0x10000(runtime)\nTimestamp=Nov 19, 2026\n' >&2 ;;
  -dr)
    if [[ "${REQUIREMENT_STDERR:-0}" = 1 ]]; then exec 1>&2; fi
    printf 'designated => identifier "com.maxmeis.hypermug" and anchor apple generic and certificate leaf[subject.OU] = TEAM123456\n'
    ;;
  -d)
    if [[ "${FAIL_ENTITLEMENTS:-0}" = 1 ]]; then exit 70; fi
    printf '%s' "${ENTITLEMENTS:-}"
    ;;
esac
''')
        codesign.chmod(0o755)
        plutil = commands / 'plutil'
        plutil.write_text('''#!/usr/bin/env bash
case "$2" in
  SUFeedURL) echo 'https://raw.githubusercontent.com/maxmeis/hypermug/updates/appcast.xml' ;;
  SUPublicEDKey) echo 'fixture-key' ;;
  SUEnableAutomaticChecks|SUVerifyUpdateBeforeExtraction) echo true ;;
  SUScheduledCheckInterval) echo 86400 ;;
  *) exit 2 ;;
esac
''')
        plutil.chmod(0o755)
        self.env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'])

    def verify(self, helper):
        return subprocess.run(['bash', str(ROOT / 'helpers' / helper), str(self.app), 'TEAM123456'],
                              cwd=ROOT, env=self.env, capture_output=True, text=True)

    def sparkle_layout(self):
        framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        (framework / 'Versions/B').mkdir(parents=True)
        (framework / 'Versions/Current').symlink_to('B')
        for name in ('Sparkle', 'Resources', 'XPCServices', 'Autoupdate', 'Updater.app'):
            (framework / name).symlink_to('Versions/Current/' + name)

    def test_app_without_entitlements_is_valid(self):
        result = self.verify('verify_production_signature.sh')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_app_entitlement_inspection_failure_stops_verification(self):
        self.env['FAIL_ENTITLEMENTS'] = '1'
        self.assertNotEqual(self.verify('verify_production_signature.sh').returncode, 0)

    def test_requirement_on_stderr_is_also_supported(self):
        self.env['REQUIREMENT_STDERR'] = '1'
        result = self.verify('verify_production_signature.sh')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_app_rejects_unexpected_entitlements(self):
        self.env['ENTITLEMENTS'] = '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
        result = self.verify('verify_production_signature.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected app entitlements', result.stderr)

    def test_app_rejects_unreadable_entitlement_plist(self):
        self.env['ENTITLEMENTS'] = 'invalid plist'
        self.assertNotEqual(self.verify('verify_production_signature.sh').returncode, 0)

    def test_nested_entitlement_inspection_failure_stops_verification(self):
        self.sparkle_layout()
        self.env['FAIL_ENTITLEMENTS'] = '1'
        self.assertNotEqual(self.verify('verify_sparkle_bundle.sh').returncode, 0)

    def test_nested_code_rejects_debugger_entitlement(self):
        self.sparkle_layout()
        self.env['ENTITLEMENTS'] = '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
        result = self.verify('verify_sparkle_bundle.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('development-only', result.stderr)

    def test_nested_code_without_entitlements_is_valid(self):
        self.sparkle_layout()
        result = self.verify('verify_sparkle_bundle.sh')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
