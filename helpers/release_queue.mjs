#!/usr/bin/env node
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { releaseConfig } from '../release.config.mjs';

function git(cwd, ...args) {
  const result = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`git ${args.join(' ')}: ${result.stderr.trim()}`);
  return result.stdout.trim();
}

function version(value) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value)) throw new Error(`Invalid production version: ${value}`);
  return value;
}

export function isPublisherCommit(repo, sha) {
  const [email, subject] = git(repo, 'show', '-s', '--format=%ae%n%s', sha).split('\n');
  if (email !== '41898282+github-actions[bot]@users.noreply.github.com' ||
      !/^chore: update Homebrew cask to \d+\.\d+\.\d+(?: \[skip release\])?$/.test(subject)) return false;
  return git(repo, 'diff-tree', '--no-commit-id', '--name-only', '-r', sha) === 'Casks/hypermug.rb';
}

export function nextSource(repo, main = 'origin/main') {
  const history = git(repo, 'rev-list', '--first-parent', main).split('\n');
  const lastPublication = history.find((sha) => isPublisherCommit(repo, sha));
  // The publisher commits the cask last. Read that machine commit rather than
  // trusting a human cask edit to advance the completed-release marker.
  const current = git(repo, 'show', `${lastPublication ?? main}:Casks/hypermug.rb`);
  const match = current.match(/^\s*version "([^"]+)"\s*$/m);
  if (!match) throw new Error('Production cask has no version marker');
  const baseline = version(match[1]);
  const baselineSha = git(repo, 'rev-parse', `v${baseline}^{commit}`);
  git(repo, 'merge-base', '--is-ancestor', baselineSha, main);
  const pending = git(repo, 'rev-list', '--first-parent', '--reverse', `${baselineSha}..${main}`);
  const sourceSha = pending.split('\n').filter(Boolean).find((sha) => !isPublisherCommit(repo, sha));
  if (!sourceSha) return null;
  const sourceTags = git(repo, 'tag', '--points-at', sourceSha).split('\n')
    .filter((tag) => /^v\d+\.\d+\.\d+$/.test(tag));
  if (sourceTags.length > 1) throw new Error(`Multiple production tags on ${sourceSha}`);
  return {
    sourceSha,
    baseline,
    existingVersion: sourceTags[0] ? version(sourceTags[0].slice(1)) : null,
    buildNumber: git(repo, 'rev-list', '--first-parent', '--count', sourceSha),
  };
}

export async function semanticPlan(repo, selection) {
  // `pending` is used by the Ubuntu preflight before npm dependencies exist.
  // Load the release engine only when an actual source needs a version.
  const { default: semanticRelease } = await import('semantic-release');
  const temp = await mkdtemp(join(tmpdir(), 'hypermug-semantic-'));
  try {
    const checkout = join(temp, 'checkout');
    const remote = join(temp, 'origin.git');
    git(repo, 'clone', '-q', '--no-local', repo, checkout);
    git(repo, 'init', '--bare', '-q', '--initial-branch=main', remote);
    // A refreshed origin/main can point past this runner's checkout. A clone
    // copies local branches, not our remote-tracking refs; fetch this source
    // explicitly so out-of-order workflow events can still drain the backlog.
    git(checkout, 'fetch', '-q', '--no-tags', repo, selection.sourceSha);
    git(checkout, 'switch', '-q', '-C', 'main', selection.sourceSha);
    git(checkout, 'remote', 'set-url', 'origin', remote);
    for (const tag of git(checkout, 'tag', '--points-at', selection.sourceSha).split('\n')) {
      if (/^v\d+\.\d+\.\d+$/.test(tag)) git(checkout, 'tag', '-d', tag);
    }
    git(checkout, 'push', '-q', 'origin', 'main');
    git(checkout, 'push', '-q', 'origin', '--tags');
    // semantic-release uses env-ci to infer its branch. This calculation runs
    // inside a local main checkout even when the outer job is a pull request.
    // Keep the explicit analysis environment free of GitHub's PR ref and job credentials.
    const analysisEnv = Object.fromEntries(
      ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM']
        .filter((key) => process.env[key] !== undefined)
        .map((key) => [key, process.env[key]]),
    );
    const result = await semanticRelease({
      ...releaseConfig(selection.sourceSha, remote),
      ci: false,
      dryRun: true,
    }, { cwd: checkout, env: analysisEnv, stdout: process.stderr, stderr: process.stderr });
    if (!result?.nextRelease) throw new Error(`semantic-release did not select a version for ${selection.sourceSha}`);
    const computed = version(result.nextRelease.version);
    if (selection.existingVersion && computed !== selection.existingVersion) {
      throw new Error(`Existing source tag v${selection.existingVersion} conflicts with semantic-release v${computed}`);
    }
    return { ...selection, version: computed, notes: result.nextRelease.notes };
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (!['next', 'pending'].includes(args[0])) throw new Error('Usage: release_queue.mjs next|pending [--repo PATH] [--main REF] [--output FILE] [--notes-file FILE]');
  function option(name, fallback) {
    const index = args.indexOf(name);
    return index < 0 ? fallback : args[index + 1];
  }
  const repo = resolve(option('--repo', process.cwd()));
  const selected = nextSource(repo, option('--main', 'origin/main'));
  if (args[0] === 'pending') {
    console.log(selected ? 'true' : 'false');
    return;
  }
  if (!selected) {
    console.log('No unreleased source commits.');
    if (option('--output', null)) await writeFile(option('--output'), 'pending=false\n', { flag: 'a' });
    return;
  }
  const plan = await semanticPlan(repo, selected);
  const notesFile = option('--notes-file', join(repo, 'build', 'release', 'release-notes.md'));
  await mkdir(dirname(notesFile), { recursive: true });
  await writeFile(notesFile, `${plan.notes.trim()}\n`);
  const output = `pending=true\nsource_sha=${plan.sourceSha}\nversion=${plan.version}\nbuild_number=${plan.buildNumber}\nnotes_file=${notesFile}\n`;
  if (option('--output', null)) await writeFile(option('--output'), output, { flag: 'a' });
  console.log(`Next release: v${plan.version} from ${plan.sourceSha} (build ${plan.buildNumber})`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().catch((error) => { console.error(error); process.exitCode = 1; });
}
