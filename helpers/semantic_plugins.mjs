import { analyzeCommits as analyze } from '@semantic-release/commit-analyzer';
import { generateNotes as notes } from '@semantic-release/release-notes-generator';
import { execFileSync } from 'node:child_process';

function oneCommit(context, sourceSha) {
  let commits = context.commits.filter((commit) => commit.hash === sourceSha);
  // semantic-release drops [skip release] commits before plugins run. A source
  // from older history can still be pending, so recover its exact Git message
  // and remove only the directive in this disposable analysis context.
  if (commits.length === 0) {
    const original = execFileSync('git', ['show', '-s', '--format=%B', sourceSha],
      { cwd: context.cwd, encoding: 'utf8' });
    const message = original.replace(/\[(?:skip release|skip ci|ci skip|no ci|skip actions|actions skip)\]/gi, '')
      .replace(/^skip-checks:\s*true\s*$/gim, '').trim();
    if (message !== original.trim()) commits = [{ hash: sourceSha, message }];
  }
  if (commits.length !== 1) throw new Error(`Expected exactly one release commit for ${sourceSha}; found ${commits.length}`);
  return { ...context, commits };
}

export async function analyzeCommits({ sourceSha }, context) {
  // Breaking changes outrank feat, and every other valid Conventional Commit
  // type (including docs, chore and ci) creates a patch release.
  return analyze({
    preset: 'conventionalcommits',
    releaseRules: [
      { breaking: true, release: 'major' },
      { type: 'feat', release: 'minor' },
      { type: '*', release: 'patch' },
    ],
  }, oneCommit(context, sourceSha));
}

export async function generateNotes({ sourceSha }, context) {
  // The version calculation runs against a temporary local remote. Generate
  // public changelog links against the real repository instead.
  const selected = oneCommit(context, sourceSha);
  return notes({
    preset: 'conventionalcommits',
    presetConfig: { types: [
      { type: 'build', section: 'Build' },
      { type: 'chore', section: 'Maintenance' },
      { type: 'ci', section: 'CI' },
      { type: 'docs', section: 'Documentation' },
      { type: 'feat', section: 'Features' },
      { type: 'fix', section: 'Fixes' },
      { type: 'perf', section: 'Performance' },
      { type: 'refactor', section: 'Refactoring' },
      { type: 'revert', section: 'Reverts' },
      { type: 'style', section: 'Style' },
      { type: 'test', section: 'Tests' },
    ] },
  }, {
    ...selected,
    options: { ...selected.options, repositoryUrl: 'https://github.com/maxmeis/hypermug.git' },
  });
}
