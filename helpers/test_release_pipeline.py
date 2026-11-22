"""Production version selection and artifact metadata regression tests."""
import base64
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree
import ed25519
from release_metadata import FEED_URL, SPARKLE, feed_decision, render_appcast, render_cask

ROOT = Path(__file__).resolve().parents[1]
SHA = 'a' * 40
SEED = bytes(range(32))


def release_zip(path, version='1.2.3', build=None, seed=SEED, feed=FEED_URL):
    """A ZIP shaped like the notarized release: HyperMug.app with its Info.plist."""
    info = {'CFBundleShortVersionString': version, 'CFBundleVersion': build or version,
            'LSMinimumSystemVersion': '14.0',
            'SUPublicEDKey': base64.b64encode(ed25519.public_key(seed)).decode()}
    if feed:
        info['SUFeedURL'] = feed
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('HyperMug.app/Contents/Info.plist', plistlib.dumps(info))
        archive.writestr('HyperMug.app/Contents/MacOS/HyperMug', b'binary')
    return path


def sparkle_signature(path, seed=SEED):
    return base64.b64encode(ed25519.sign(seed, Path(path).read_bytes())).decode()


class ReleasePipelineTests(unittest.TestCase):
    def test_cask_uses_exact_archive_digest_and_declares_in_app_updates(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'HyperMug-1.2.3.zip'
            archive.write_bytes(b'final notarized app archive')
            cask = Path(folder) / 'hypermug.rb'
            result = subprocess.run([sys.executable, str(ROOT / 'helpers/release_metadata.py'),
                'cask', '--version', '1.2.3', '--zip', str(archive), '--output', str(cask)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(cask.read_text(), render_cask('1.2.3', digest))
            self.assertIn(f'sha256 "{digest}"', cask.read_text())
            self.assertIn('  auto_updates true\n', cask.read_text())
            self.assertIn('conflicts_with cask: "hypermug@canary"', cask.read_text())

    @unittest.skipUnless(shutil.which('brew'), 'Homebrew is unavailable')
    def test_generated_cask_loads_in_homebrew_and_checks_resolved_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'HyperMug-1.2.3.zip'
            archive.write_bytes(b'immutable release bytes')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            cask = Path(folder) / 'hypermug.rb'
            cask.write_text(render_cask('1.2.3', digest))
            command = [str(ROOT / 'helpers/validate-cask.sh'), str(cask), '1.2.3', digest]
            valid = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            legacy_command = [
                'brew', 'ruby', '-e',
                'require "cask/cask_loader"; '
                'Cask::CaskLoader.singleton_class.send(:remove_method, :from_content) '
                'if Cask::CaskLoader.respond_to?(:from_content); '
                'load ARGV.shift',
                str(ROOT / 'helpers/validate_cask.rb'), str(cask), '1.2.3', digest,
            ]
            env = dict(os.environ,
                       HOMEBREW_CACHE=str(Path(folder) / 'brew-cache'),
                       HOMEBREW_TEMP=str(Path(folder) / 'brew-temp'),
                       HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_INSTALL_FROM_API='1')
            legacy = subprocess.run(legacy_command, env=env, capture_output=True, text=True)
            self.assertEqual(legacy.returncode, 0, legacy.stderr)
            wrong_digest = subprocess.run(command[:-1] + ['0' * 64], capture_output=True, text=True)
            self.assertNotEqual(wrong_digest.returncode, 0)
            self.assertIn('unexpected Cask digest', wrong_digest.stderr)

    def test_malformed_version_cannot_enter_cask_or_release(self):
        for bad in ('1.2', '01.2.3', '1.2.3-rc.1', '1.2.3;echo bad'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                render_cask(bad, 'a' * 64)

    def test_appcast_describes_the_exact_signed_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = release_zip(Path(folder) / 'HyperMug-1.2.3.zip', build='1.2.3')
            signature = sparkle_signature(archive)
            output = Path(folder) / 'appcast.xml'
            result = subprocess.run([sys.executable, str(ROOT / 'helpers/release_metadata.py'), 'appcast',
                '--version', '1.2.3', '--build-number', '1.2.3', '--zip', str(archive), '--signature', signature, '--output', str(output)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            item = ElementTree.fromstring(output.read_text()).find('./channel/item')
            self.assertEqual(item.findtext(f'{{{SPARKLE}}}version'), '1.2.3')
            self.assertEqual(item.findtext(f'{{{SPARKLE}}}shortVersionString'), '1.2.3')
            self.assertEqual(item.findtext(f'{{{SPARKLE}}}minimumSystemVersion'), '14.0')
            enclosure = item.find('enclosure')
            self.assertEqual(enclosure.get('url'),
                             'https://github.com/maxmeis/hypermug/releases/download/v1.2.3/HyperMug-1.2.3.zip')
            self.assertEqual(enclosure.get('length'), str(archive.stat().st_size))
            self.assertEqual(enclosure.get(f'{{{SPARKLE}}}edSignature'), signature)

    def test_appcast_uses_bundle_version_for_sparkle_ordering(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = release_zip(Path(folder) / 'a.zip', build='42')
            feed = render_appcast('1.2.3', archive, sparkle_signature(archive))
            self.assertIn('<sparkle:version>42</sparkle:version>', feed)
            self.assertIn('<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>', feed)
            with self.assertRaisesRegex(ValueError, 'build number'):
                render_appcast('1.2.3', archive, sparkle_signature(archive), expected_build='43')

    def test_appcast_rejects_signatures_the_installed_app_cannot_verify(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = release_zip(Path(folder) / 'a.zip')
            cases = {
                'other key': sparkle_signature(archive, bytes(32)),
                'other bytes': base64.b64encode(ed25519.sign(SEED, b'other archive')).decode(),
                'not base64': 'not a signature!',
            }
            for name, signature in cases.items():
                with self.subTest(name), self.assertRaises(ValueError):
                    render_appcast('1.2.3', archive, signature)

    def test_appcast_rejects_archives_that_are_not_this_production_release(self):
        with tempfile.TemporaryDirectory() as folder:
            wrong_version = release_zip(Path(folder) / 'v.zip', version='1.2.4')
            no_feed = release_zip(Path(folder) / 'dev.zip', feed=None)
            other_feed = release_zip(Path(folder) / 'other.zip', feed='https://example.invalid/appcast.xml')
            for archive in (wrong_version, no_feed, other_feed):
                with self.subTest(archive.name), self.assertRaises(ValueError):
                    render_appcast('1.2.3', archive, sparkle_signature(archive))

    def test_feed_only_moves_forward_and_reruns_are_noops(self):
        with tempfile.TemporaryDirectory() as folder:
            def feed(version, payload=b''):
                archive = release_zip(Path(folder) / f'{version}.zip', version=version)
                if payload:
                    with zipfile.ZipFile(archive, 'a') as bundle:
                        bundle.writestr('extra', payload)
                return render_appcast(version, archive, sparkle_signature(archive))
            old, new, newer = feed('0.3.0'), feed('0.3.9'), feed('0.3.10')
            self.assertEqual(feed_decision(None, new), 'advance')
            self.assertEqual(feed_decision(old, new), 'advance')
            self.assertEqual(feed_decision(new, newer), 'advance', 'numeric, not lexical, ordering')
            self.assertEqual(feed_decision(newer, new), 'newer')
            self.assertEqual(feed_decision(new, new), 'current')
            with self.assertRaises(ValueError):
                feed_decision(new, feed('0.3.9', b'rebuilt bytes'))
            with self.assertRaises(ValueError):
                feed_decision('<rss><channel/></rss>', new)

    def test_ed25519_matches_rfc8032_test_vector(self):
        # RFC 8032 section 7.1, TEST 1.
        seed = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
        public = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
                                  '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        self.assertEqual(ed25519.public_key(seed), public)
        self.assertEqual(ed25519.sign(seed, b''), signature)
        self.assertTrue(ed25519.verify(public, b'', signature))
        self.assertFalse(ed25519.verify(public, b'x', signature))

    def test_release_requires_credentials_before_build(self):
        env = {'VERSION': '1.2.3', 'BUILD_NUMBER': '42', 'GITHUB_SHA': SHA,
               'GITHUB_REPOSITORY': 'maxmeis/hypermug'}
        # A missing Developer ID is an early failure, before any app build.
        import os
        values = os.environ.copy()
        for key in ('SIGN_ID', 'DEVELOPER_ID_P12_BASE64', 'DEVELOPER_ID_P12_PASSWORD', 'APPLE_TEAM_ID'):
            values.pop(key, None)
        values.update(env)
        result = subprocess.run(['bash', str(ROOT / 'helpers/release.sh')], env=values,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SIGN_ID', result.stderr)


class SignedReleaseIntegrationTests(unittest.TestCase):
    """The release wrapper must publish only an Accepted notarized bundle."""
    def setUp(self):
        import os, shutil
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / 'project'
        helpers = self.project / 'helpers'
        helpers.mkdir(parents=True)
        for name in ('release.sh', 'release_metadata.py', 'ed25519.py', 'notary_auth.sh'):
            shutil.copy2(ROOT / 'helpers' / name, helpers / name)
        (helpers / 'verify_production_signature.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
        (helpers / 'verify_production_signature.sh').chmod(0o755)
        (helpers / 'verify_release_archive.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
        (helpers / 'verify_release_archive.sh').chmod(0o755)
        (helpers / 'check-bundle-schema.py').write_text('pass\n')
        sparkle = helpers / 'verify_sparkle_bundle.sh'
        sparkle.write_text('#!/usr/bin/env bash\necho "verify_sparkle_bundle $*" >> "$MOCK_LOG"\n')
        sparkle.chmod(0o755)
        subprocess.run(['git', 'init', '-q', str(self.project)], check=True)
        (self.project / 'README').write_text('fixture')
        subprocess.run(['git', '-C', str(self.project), 'add', 'README'], check=True)
        subprocess.run(['git', '-C', str(self.project), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.sha = subprocess.check_output(['git', '-C', str(self.project), 'rev-parse', 'HEAD'], text=True).strip()
        self.bin = Path(self.temp.name) / 'bin'
        self.bin.mkdir()
        self.log = Path(self.temp.name) / 'calls'
        fixtures = {
            'security': '''
if [[ "$1" == list-keychains && "${4:-}" != -s ]]; then echo '"/tmp/login.keychain-db"'; fi
if [[ "$1" == find-identity ]]; then echo '  1) FAKE "Developer ID Application: Example"'; fi
''',
            # The production wrapper uses macOS base64 -D; emulate decoding on Linux CI too.
            'base64': "python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))'",
            'openssl': 'echo fakepassword',
            'make': '''
mkdir -p build/HyperMug.app/Contents
printf plist > build/HyperMug.app/Contents/Info.plist
''',
            'plutil': '''
case "$2" in
  CFBundleShortVersionString) echo 1.2.3;;
  CFBundleVersion) echo 42;;
  CFBundleIdentifier) echo com.maxmeis.hypermug;;
  *) exit 1;;
esac
''',
            'codesign': 'if [[ "$1" == -dv ]]; then printf "TeamIdentifier=TEAM123\\nCodeDirectory flags=0x10000(runtime)\\nTimestamp=Nov 17, 2026\\n" >&2; fi',
            'spctl': ':',
            'ditto': 'printf "signed and notarized archive" > "${@: -1}"',
            'xcrun': '''
if [[ "$1" == notarytool ]]; then
  echo "{\\"status\\":\\"${NOTARY_STATUS:-Accepted}\\"}"
fi
''',
        }
        for name, body in fixtures.items():
            path = self.bin / name
            path.write_text('#!/usr/bin/env bash\nset -e\necho "' + name + ' $*" >> "$MOCK_LOG"\n' + body)
            path.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=f'{self.bin}:{os.environ["PATH"]}', MOCK_LOG=str(self.log),
                        VERSION='1.2.3', BUILD_NUMBER='42', GITHUB_SHA=self.sha, GITHUB_REPOSITORY='maxmeis/hypermug',
                        SIGN_ID='Developer ID Application: Example', DEVELOPER_ID_P12_BASE64='YQ==',
                        DEVELOPER_ID_P12_PASSWORD='fixture', APPLE_TEAM_ID='TEAM123',
                        APP_STORE_CONNECT_PRIVATE_KEY='fixture-key', APP_STORE_CONNECT_KEY_ID='KEY123',
                        APP_STORE_CONNECT_ISSUER_ID='ISSUER123')

    def run_release(self, status='Accepted'):
        env = dict(self.env, NOTARY_STATUS=status)
        return subprocess.run(['bash', 'helpers/release.sh'], cwd=self.project, env=env,
                              capture_output=True, text=True)

    def test_accepted_notarization_produces_final_archive_and_cleans_keychain(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertLess(calls.index('verify_sparkle_bundle build/HyperMug.app TEAM123'), calls.index('xcrun notarytool submit'))
        self.assertLess(calls.index('xcrun notarytool submit'), calls.index('xcrun stapler staple'))
        self.assertLess(calls.index('xcrun stapler validate'), calls.rindex('ditto -c'))
        self.assertIn('security delete-keychain', calls)
        archive = self.project / 'build/release/HyperMug-1.2.3.zip'
        self.assertTrue(archive.is_file())
        self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(),
                      (self.project / 'build/release/hypermug.rb').read_text())

    def test_rejected_notarization_never_publishes_archive_and_cleans_keychain(self):
        result = self.run_release('Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Notarization was not accepted', result.stderr)
        self.assertNotIn('xcrun stapler staple', self.log.read_text())
        self.assertIn('security delete-keychain', self.log.read_text())
        self.assertFalse((self.project / 'build/release/HyperMug-1.2.3.zip').exists())


if __name__ == '__main__':
    unittest.main()
