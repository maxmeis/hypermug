import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { analyzeCommits } from './semantic_plugins.mjs';
import { isPublisherCommit, nextSource, semanticPlan } from './release_queue.mjs';

function git(repo, ...args) {
  const env = { ...process.env };
  for (const key of ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']) delete env[key];
  const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8', env });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'hypermug-queue-test-'));
  const repo = join(dir, 'repo');
  mkdirSync(repo);
  git(repo, 'init', '-q', '-b', 'main');
  git(repo, 'config', 'user.name', 'Example');
  git(repo, 'config', 'user.email', 'example@example.invalid');
  mkdirSync(join(repo, 'Casks'));
  writeFileSync(join(repo, 'Casks/hypermug.rb'), 'cask "hypermug" do\n  version "0.3.3"\nend\n');
  git(repo, 'add', '.');
  git(repo, 'commit', '-qm', 'chore: baseline');
  git(repo, 'tag', 'v0.3.3');
  return { repo, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function commit(repo, message, file = 'README.md', author = 'Example <example@example.invalid>') {
  writeFileSync(join(repo, file), `${Date.now()} ${Math.random()}\n`, { flag: 'a' });
  git(repo, 'add', file);
  git(repo, '-c', `user.name=${author.split(' <')[0]}`, '-c', `user.email=${author.split('<')[1].slice(0, -1)}`, 'commit', '-qm', message);
  return git(repo, 'rev-parse', 'HEAD');
}

function caskCommit(repo, version) {
  writeFileSync(join(repo, 'Casks/hypermug.rb'), `cask "hypermug" do\n  version "${version}"\nend\n`);
  git(repo, 'add', 'Casks/hypermug.rb');
  git(repo, '-c', 'user.name=github-actions[bot]',
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit', '-qm', `chore: update Homebrew cask to ${version} [skip release]`);
  return git(repo, 'rev-parse', 'HEAD');
}

const logger = { log() {}, error() {}, success() {} };

test('scheduled no-op releases stop on Ubuntu and PR CI does not rerun on main', () => {
  const release = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const preflight = release.split(/^  preflight:\s*$/m)[1]?.split(/^  release:\s*$/m)[0];
  assert.ok(preflight, 'release workflow needs a preflight job');
  assert.match(preflight, /runs-on: ubuntu-latest/);
  assert.doesNotMatch(preflight, /npm ci|macos-latest/);
  assert.match(release, /^  release:\n    needs: preflight\n    if: needs\.preflight\.outputs\.pending == 'true'\n    runs-on: macos-latest/m);
  assert.doesNotMatch(ci, /^  push:/m);
  assert.match(ci, /^  pull_request:/m);
});

test('Conventional Commit policy releases every valid type and breaking change', async () => {
  async function kind(message) {
    const sha = 'a'.repeat(40);
    return analyzeCommits({ sourceSha: sha }, { commits: [{ hash: sha, message }], logger });
  }
  assert.equal(await kind('fix: repair'), 'patch');
  assert.equal(await kind('docs: update guide'), 'patch');
  assert.equal(await kind('chore: housekeeping'), 'patch');
  assert.equal(await kind('ci: update action'), 'patch');
  assert.equal(await kind('feat: add button'), 'minor');
  assert.equal(await kind('feat!: remove old API'), 'major');
  assert.equal(await kind('feat!: remove old API\n\nBREAKING CHANGE: old API removed'), 'major');
  assert.equal(await kind('fix: change protocol\n\nBREAKING CHANGE: protocol changed'), 'major');
});

test('two quick merges select oldest source, then retry source tag, then next source', async (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  const first = commit(repo, 'docs: explain shortcuts');
  const second = commit(repo, 'feat: add widget');
  let selected = nextSource(repo, 'main');
  assert.equal(selected.sourceSha, first);
  assert.equal(selected.existingVersion, null);
  const firstPlan = await semanticPlan(repo, selected);
  assert.equal(firstPlan.version, '0.3.4');
  assert.match(firstPlan.notes, /shortcuts/);
  git(repo, 'tag', 'v0.3.4', first);
  selected = nextSource(repo, 'main');
  assert.equal(selected.sourceSha, first);
  assert.equal(selected.existingVersion, '0.3.4');
  assert.equal((await semanticPlan(repo, selected)).version, '0.3.4');
  const bot = caskCommit(repo, '0.3.4');
  assert.equal(isPublisherCommit(repo, bot), true);
  selected = nextSource(repo, 'main');
  assert.equal(selected.sourceSha, second);
  assert.ok(Number(selected.buildNumber) > Number(firstPlan.buildNumber));
  assert.equal((await semanticPlan(repo, selected)).version, '0.4.0');
});

test('only exact machine cask commits are skipped', (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  const human = commit(repo, 'chore: update Homebrew cask to 0.3.4', 'README.md');
  assert.equal(isPublisherCommit(repo, human), false);
  assert.equal(nextSource(repo, 'main').sourceSha, human);
});

test('semantic-release analyzes a source commit even with a skip-release phrase', async (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  const source = commit(repo, 'docs: explain the literal [skip release] marker');
  assert.equal(nextSource(repo, 'main').sourceSha, source);
  assert.equal((await semanticPlan(repo, nextSource(repo, 'main'))).version, '0.3.4');
});

test('backlog dispatch gate is true only while a source remains', (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  mkdirSync(join(repo, 'helpers'));
  copyFileSync(new URL('./release_queue.mjs', import.meta.url), join(repo, 'helpers/release_queue.mjs'));
  copyFileSync(new URL('../release.config.mjs', import.meta.url), join(repo, 'release.config.mjs'));
  writeFileSync(join(repo, 'package.json'), '{"type":"module"}\n');
  function pending() {
    const result = spawnSync(process.execPath,
      [join(repo, 'helpers/release_queue.mjs'), 'pending', '--repo', repo, '--main', 'main'],
      { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  }
  assert.equal(pending(), 'false');
  const source = commit(repo, 'ci: bump action');
  assert.equal(pending(), 'true');
  git(repo, 'tag', 'v0.3.4', source);
  caskCommit(repo, '0.3.4');
  assert.equal(pending(), 'false');
});

test('semantic-release gives a breaking source its major version', async (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  commit(repo, 'feat!: remove legacy API\n\nBREAKING CHANGE: legacy API is removed');
  assert.equal((await semanticPlan(repo, nextSource(repo, 'main'))).version, '1.0.0');
});

test('queue works from the detached HEAD used by Actions checkout', async (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  const source = commit(repo, 'fix: repair a shortcut');
  git(repo, 'checkout', '-q', '--detach', source);
  assert.equal((await semanticPlan(repo, nextSource(repo, 'HEAD'))).version, '0.3.4');
});

test('semantic dry run ignores the outer GitHub pull-request ref', (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  commit(repo, 'fix: repair PR release selection');
  const env = {
    ...process.env,
    CI: 'true',
    GITHUB_ACTIONS: 'true',
    GITHUB_EVENT_NAME: 'pull_request',
    GITHUB_REF: 'refs/pull/57/merge',
    GITHUB_HEAD_REF: 'fix/release-selection',
    GITHUB_BASE_REF: 'main',
    GITHUB_SHA: 'f'.repeat(40),
    GH_TOKEN: 'dry-run-token-must-not-appear',
  };
  const result = spawnSync(process.execPath,
    [new URL('./release_queue.mjs', import.meta.url).pathname, 'next', '--repo', repo,
      '--main', 'main', '--notes-file', join(repo, 'notes.md')],
    { encoding: 'utf8', env });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Next release: v0\.3\.4/);
  assert.doesNotMatch(result.stderr, /refs\/pull\/57\/merge/);
  assert.doesNotMatch(result.stderr, /dry-run-token-must-not-appear/);
  assert.match(readFileSync(join(repo, 'notes.md'), 'utf8'), /repair PR release selection/);
});

test('semantic dry run works when Git defaults new bare repos to master', (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  commit(repo, 'docs: explain release queue');
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'init.defaultBranch',
    GIT_CONFIG_VALUE_0: 'master',
  };
  const result = spawnSync(process.execPath,
    [new URL('./release_queue.mjs', import.meta.url).pathname, 'next', '--repo', repo,
      '--main', 'main', '--notes-file', join(repo, 'notes.md')],
    { encoding: 'utf8', env });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Next release: v0\.3\.4/);
});

test('queue can release refreshed main beyond the runner checkout', async (t) => {
  const { repo, cleanup } = fixture();
  t.after(cleanup);
  const baseline = git(repo, 'rev-parse', 'HEAD');
  const source = commit(repo, 'docs: update after this runner started');
  git(repo, 'update-ref', 'refs/remotes/origin/main', source);
  git(repo, 'reset', '--hard', baseline);
  const selection = nextSource(repo, 'origin/main');
  assert.equal(selection.sourceSha, source);
  assert.equal((await semanticPlan(repo, selection)).version, '0.3.4');
});
