"""Publish a release once, then update the Sparkle appcast and the one-repository cask directly."""
import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree
import ed25519
from release_metadata import SPARKLE
from test_release_pipeline import release_zip

ROOT = Path(__file__).resolve().parents[1]
SEED = bytes(range(32))
SECRET = base64.b64encode(SEED).decode()
# Mirrors `sign_update --ed-key-file - -p FILE`: key on stdin, signature only on stdout.
FAKE_SIGN_UPDATE = f'''#!/usr/bin/env python3
import base64, os, sys
sys.path.insert(0, {str(ROOT / 'helpers')!r})
import ed25519
args = sys.argv[1:]
if args[:3] != ['--ed-key-file', '-', '-p'] or len(args) != 4: sys.exit('unexpected sign_update ' + repr(args))
with open(os.environ['SIGN_LOG'], 'a') as log: log.write(args[3] + '\\n')
seed = base64.b64decode(sys.stdin.read().strip())
print(base64.b64encode(ed25519.sign(seed, open(args[3], 'rb').read())).decode())
'''
FAKE_GH = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_path = Path(os.environ['RELEASE_STATE'])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
def save(): state_path.write_text(json.dumps(state))
if args[0] == 'api':
    if args[1].endswith('/releases/latest'):
        if os.environ.get('FAKE_LATEST_TAG'):
            print(os.environ['FAKE_LATEST_TAG']); sys.exit(0)
        print('HTTP 404', file=sys.stderr); sys.exit(1)
    sys.exit(2)
elif args[:2] == ['release', 'view']:
    if not state['exists']: sys.exit(1)
    field = args[args.index('--jq') + 1] if '--jq' in args else ''
    if field == '.body': print(state['body'])
    elif field == '.isDraft': print(str(state['draft']).lower())
    elif field == '.assets[].name':
        if state['asset']: print(state['asset_name'])
        if state.get('checksum'): print('SHA256SUMS')
    else: print('{}')
elif args[:2] == ['release', 'create']:
    if state['exists']: sys.exit(2)
    state['exists'] = True
    state['draft'] = True
    state['body'] = Path(args[args.index('--notes-file') + 1]).read_text().rstrip()
    file = Path(args[3]); state['asset_name'] = file.name; state['asset'] = file.read_bytes().hex()
    state['creates'] += 1; save()
elif args[:2] == ['release', 'download']:
    if not state['exists']: sys.exit(3)
    pattern = args[args.index('--pattern') + 1]
    file = Path(args[args.index('--dir') + 1]) / pattern
    if pattern == state['asset_name'] and state['asset']: file.write_bytes(bytes.fromhex(state['asset']))
    elif pattern == 'SHA256SUMS' and state.get('checksum'): file.write_bytes(bytes.fromhex(state['checksum']))
    else: sys.exit(3)
elif args[:2] == ['release', 'edit']:
    state['draft'] = False; state['publishes'] += 1
    state['latest_flag'] = '--latest=false' if '--latest=false' in args else '--latest'
    save()
elif args[:2] == ['release', 'upload']:
    if not state['draft']: sys.exit(4)
    file = Path(args[3])
    if file.name == 'SHA256SUMS': state['checksum'] = file.read_bytes().hex()
    elif not state['asset']: state['asset_name'] = file.name; state['asset'] = file.read_bytes().hex()
    else: sys.exit(4)
    save()
else: sys.exit('Unsupported gh: ' + repr(args))
'''


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.remote = base / 'remote.git'
        self.repo = base / 'repo'
        subprocess.run(['git', 'init', '--bare', '-q', str(self.remote)], check=True)
        subprocess.run(['git', 'clone', '-q', str(self.remote), str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'switch', '-qc', 'main'], check=True)
        (self.repo / 'helpers').mkdir()
        for name in ('publish_release.sh', 'release_metadata.py', 'ed25519.py',
                     'validate-cask.sh', 'validate_cask.rb'):
            shutil.copy2(ROOT / 'helpers' / name, self.repo / 'helpers' / name)
        sparkle = base / 'sparkle'
        (sparkle / 'bin').mkdir(parents=True)
        (sparkle / 'bin/sign_update').write_text(FAKE_SIGN_UPDATE)
        (sparkle / 'bin/sign_update').chmod(0o755)
        (self.repo / 'helpers/sparkle.sh').write_text(f'SPARKLE_ROOT={sparkle}\nsparkle_prepare() {{ :; }}\n')
        verifier = self.repo / 'helpers/verify_release_archive.sh'
        verifier.write_text('#!/usr/bin/env bash\nif [[ "${FAIL_VERIFY:-0}" == 1 ]]; then exit 1; fi\nexit 0\n')
        verifier.chmod(0o755)
        (self.repo / 'Casks').mkdir()
        (self.repo / 'Casks/hypermug.rb').write_text('cask "hypermug" do\n  version "0.2.0"\nend\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'source')
        self.sha = self.git('rev-parse', 'HEAD').stdout.strip()
        self.git('tag', 'v0.2.1')
        self.git('push', '-q', 'origin', 'main', 'v0.2.1')
        archive = self.repo / 'build/release/HyperMug-0.2.1.zip'
        archive.parent.mkdir(parents=True)
        release_zip(archive, version='0.2.1', build='42', seed=SEED)
        self.notes = self.repo / 'release-notes.md'
        self.notes.write_text('## Fixes\n\n- Example change.\n')
        self.sign_log = base / 'signed'
        self.state = base / 'state.json'
        self.state.write_text(json.dumps(dict(exists=False, draft=False, body='', asset_name='',
                                              asset='', creates=0, publishes=0)))
        bin_dir = base / 'bin'
        bin_dir.mkdir()
        gh = bin_dir / 'gh'
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        brew = bin_dir / 'brew'
        brew.write_text('#!/usr/bin/env bash\n'
                        '[[ "$1" == ruby ]] || exit 2\n'
                        'printf "%s\\n" "$*" >> "$BREW_LOG"\n'
                        '[[ "${FAKE_BREW_FAIL:-0}" != 1 ]] || exit 3\n'
                        'test -s "$3"\n')
        brew.chmod(0o755)
        self.brew_log = base / 'brew-calls'
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                        RELEASE_STATE=str(self.state), VERSION='0.2.1', BUILD_NUMBER='42', GITHUB_SHA=self.sha,
                        GITHUB_REPOSITORY='maxmeis/hypermug', GH_TOKEN='fixture-token',
                        APPLE_TEAM_ID='TEAM123', SPARKLE_ED_PRIVATE_KEY=SECRET,
                        SIGN_LOG=str(self.sign_log), BREW_LOG=str(self.brew_log),
                        RELEASE_NOTES_FILE=str(self.notes))

    def git(self, *args):
        result = subprocess.run(['git', '-C', str(self.repo), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def publish(self):
        result = subprocess.run(['bash', 'helpers/publish_release.sh'], cwd=self.repo, env=self.env,
                                capture_output=True, text=True)
        self.assertNotIn(SECRET, result.stdout + result.stderr, 'private key must never be printed')
        return result

    def remote_feed(self):
        result = subprocess.run(['git', '--git-dir', str(self.remote), 'show', 'updates:appcast.xml'],
                                capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None

    def feed_commits(self):
        return subprocess.run(['git', '--git-dir', str(self.remote), 'rev-list', '--count', 'updates'],
                              capture_output=True, text=True, check=True).stdout.strip()

    def seed_feed(self, version, name='appcast.xml'):
        """Publish a pre-existing updates branch, as left by an earlier release."""
        seeded = Path(self.temp.name) / 'seeded'
        subprocess.run(['git', 'init', '-q', str(seeded)], check=True)
        (seeded / name).write_text(
            f'<rss xmlns:sparkle="{SPARKLE}"><channel><item><sparkle:version>{version}</sparkle:version>'
            '</item></channel></rss>\n')
        for args in (['add', '.'], ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'feed'],
                     ['push', '-q', str(self.remote), 'HEAD:refs/heads/updates']):
            subprocess.run(['git', '-C', str(seeded), *args], check=True)
        return self.remote_feed()

    def test_signs_published_archive_and_commits_appcast_to_updates_branch(self):
        old = self.seed_feed('41')
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.remote_feed()
        self.assertNotEqual(feed, old)
        item = ElementTree.fromstring(feed).find('./channel/item')
        self.assertEqual(item.findtext(f'{{{SPARKLE}}}version'), '42')
        enclosure = item.find('enclosure')
        published = bytes.fromhex(json.loads(self.state.read_text())['asset'])
        self.assertEqual(enclosure.get('length'), str(len(published)))
        self.assertTrue(ed25519.verify(ed25519.public_key(SEED), published,
                                       base64.b64decode(enclosure.get(f'{{{SPARKLE}}}edSignature'))))
        # sign_update ran on the downloaded copy, not the local build output.
        signed = self.sign_log.read_text().splitlines()
        self.assertEqual(len(signed), 2)
        self.assertNotEqual(Path(signed[-1]).resolve(), (self.repo / 'build/release/HyperMug-0.2.1.zip').resolve())
        self.assertEqual(self.feed_commits(), '2')

    def test_publisher_only_ever_touches_appcast_xml(self):
        # The 0.3.0 feed trusts the lost key; a new-key item there would show users a signature error.
        self.seed_feed('0.3.0', name='appcast-stable.xml')
        frozen = subprocess.run(['git', '--git-dir', str(self.remote), 'show', 'updates:appcast-stable.xml'],
                                capture_output=True, check=True).stdout
        for _ in range(2):
            result = self.publish()
            self.assertEqual(result.returncode, 0, result.stderr)
        log = subprocess.run(['git', '--git-dir', str(self.remote), 'log', '--format=', '--name-only', 'updates'],
                             capture_output=True, text=True, check=True).stdout.split()
        # One seed commit plus exactly one publisher commit, which changes appcast.xml alone.
        self.assertEqual(log, ['appcast.xml', 'appcast-stable.xml'])
        self.assertEqual(subprocess.run(['git', '--git-dir', str(self.remote), 'show', 'updates:appcast-stable.xml'],
                                        capture_output=True, check=True).stdout, frozen)

    def test_newer_feed_is_never_moved_backward(self):
        newer = self.seed_feed('43')
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('newer production appcast', result.stdout)
        self.assertEqual(self.remote_feed(), newer)
        self.assertEqual(self.feed_commits(), '1')

    def test_missing_signing_secret_fails_before_any_release_change(self):
        for value in (None, ''):
            with self.subTest(value=value):
                if value is None:
                    self.env.pop('SPARKLE_ED_PRIVATE_KEY', None)
                else:
                    self.env['SPARKLE_ED_PRIVATE_KEY'] = value
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('SPARKLE_ED_PRIVATE_KEY is required', result.stderr)
                state = json.loads(self.state.read_text())
                self.assertEqual((state['exists'], state['creates']), (False, 0))
                self.assertIsNone(self.remote_feed())
                self.assertEqual(self.git('rev-parse', 'origin/main').stdout.strip(), self.sha)

    def test_failed_archive_verification_creates_no_tag_or_release(self):
        self.git('push', '--delete', 'origin', 'v0.2.1')
        self.git('tag', '-d', 'v0.2.1')
        self.env['FAIL_VERIFY'] = '1'
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(self.state.read_text())['exists'])
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(self.remote),
            'tag', '-l', 'v0.2.1'], text=True).strip(), '')
        self.assertIsNone(self.remote_feed())

    def test_invalid_cask_fails_homebrew_loader_before_tag_or_release(self):
        self.git('push', '--delete', 'origin', 'v0.2.1')
        self.git('tag', '-d', 'v0.2.1')
        self.env['FAKE_BREW_FAIL'] = '1'
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.brew_log.read_text().startswith('ruby '))
        self.assertFalse(json.loads(self.state.read_text())['exists'])
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(self.remote),
            'tag', '-l', 'v0.2.1'], text=True).strip(), '')

    def test_release_notes_and_checksum_match_final_archive(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        self.assertIn(f'HyperMug 0.2.1; source {self.sha}; build 42', state['body'])
        self.assertIn('Example change.', state['body'])
        expected = __import__('hashlib').sha256(bytes.fromhex(state['asset'])).hexdigest()
        self.assertEqual(bytes.fromhex(state['checksum']).decode(),
                         f'{expected}  HyperMug-0.2.1.zip\n')
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.sha)

    def test_checksum_mismatch_on_retry_fails_without_republishing(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        state['checksum'] = (b'0' * 64).hex()
        self.state.write_text(json.dumps(state))
        retry = self.publish()
        self.assertNotEqual(retry.returncode, 0)
        self.assertIn('Checksum asset differs', retry.stderr)
        self.assertEqual(json.loads(self.state.read_text())['publishes'], 1)

    def test_secret_that_does_not_match_the_app_key_prevents_release_creation(self):
        self.git('push', '--delete', 'origin', 'v0.2.1')
        self.git('tag', '-d', 'v0.2.1')
        self.env['SPARKLE_ED_PRIVATE_KEY'] = base64.b64encode(bytes(32)).decode()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SUPublicEDKey", result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual((state['exists'], state['publishes']), (False, 0))
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(self.remote),
            'tag', '-l', 'v0.2.1'], text=True).strip(), '')
        self.assertIsNone(self.remote_feed())
        self.assertEqual(self.git('rev-parse', 'origin/main').stdout.strip(), self.sha)

    def test_publishes_exact_archive_and_direct_cask_commit_then_rerun_is_idempotent(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual((state['creates'], state['publishes']), (1, 1))
        cask = subprocess.check_output(['git', '--git-dir', str(self.remote), 'show', 'main:Casks/hypermug.rb'], text=True)
        self.assertIn('version "0.2.1"', cask)
        self.assertIn('sha256 "', cask)
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(self.remote), 'rev-list', '--count', self.sha + '..main'], text=True).strip(), '1')
        # A retry must use the already-published immutable asset even after a rebuild.
        (self.repo / 'build/release/HyperMug-0.2.1.zip').write_bytes(b'different rebuild')
        feed = self.remote_feed()
        self.assertIsNotNone(feed, 'first release creates the updates branch')
        retry = self.publish()
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertEqual(json.loads(self.state.read_text())['creates'], 1)
        self.assertEqual(self.remote_feed(), feed)
        self.assertEqual(self.feed_commits(), '1')
        self.assertEqual(subprocess.check_output(['git', '--git-dir', str(self.remote), 'rev-list', '--count', self.sha + '..main'], text=True).strip(), '1')

    def test_existing_release_for_other_source_is_rejected(self):
        state = json.loads(self.state.read_text())
        state.update(exists=True, body='HyperMug 0.2.1; source ' + 'f' * 40)
        self.state.write_text(json.dumps(state))
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('different source', result.stderr)
        self.assertEqual(self.git('rev-parse', 'origin/main').stdout.strip(), self.sha)

    def test_older_draft_does_not_replace_newer_latest_release(self):
        state = json.loads(self.state.read_text())
        state.update(exists=True, draft=True, body=f'HyperMug 0.2.1; source {self.sha}',
                     asset_name='HyperMug-0.2.1.zip',
                     asset=(self.repo / 'build/release/HyperMug-0.2.1.zip').read_bytes().hex())
        self.state.write_text(json.dumps(state))
        self.env['FAKE_LATEST_TAG'] = 'v0.2.2'
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.state.read_text())['latest_flag'], '--latest=false')


if __name__ == '__main__':
    unittest.main()
