import test from 'node:test';
import assert from 'node:assert/strict';
import { classify, missingComment, productionVersions, reportedVersion, triage, poll } from './triage-issues.mjs';

const body = `### HyperMug marketing version\n1.2.3\n\n### HyperMug build number\n456\n\n### Install source\nGitHub production release`;
const releases = [
  { tag_name: 'v1.2.4', draft: false, prerelease: false, assets: [{ name: 'HyperMug-1.2.4.zip' }] },
  { tag_name: 'v1.2.3', draft: false, prerelease: false, assets: [{ name: 'HyperMug-1.2.3.zip' }] },
  { tag_name: 'v1.3.0-beta.1', draft: false, prerelease: true, assets: [] },
];

test('parses exact form fields and checks only published production tags', () => {
  assert.deepEqual(reportedVersion(body), { marketing: '1.2.3', build: '456', complete: true });
  assert.deepEqual(productionVersions(releases), ['1.2.4', '1.2.3']);
  assert.equal(classify(body, releases), 'version:older');
  assert.equal(classify(body.replace('1.2.3', '1.2.4'), releases), 'version:current');
  assert.equal(classify(body.replace('GitHub production release', 'Built from source'), releases), 'version:local');
  assert.equal(classify(body.replace('1.2.3', '0.9.0'), releases), 'version:unverified');
  assert.equal(classify(body.replace('456', 'not known yet'), releases), 'needs-version');
  assert.equal(classify(body.replace('1.2.3', 'unknown'), releases), 'needs-version');
  assert.equal(classify(body, null), null);
  assert.match(missingComment(body.replace('456', '_No response_')), /build number/);
  assert.match(missingComment(body.replace('1.2.3', 'unknown')), /marketing version/);
});

test('current means highest installed app version, regardless of release publication date', () => {
  const history = [
    { tag_name: 'v1.9.0', published_at: '2026-02-01', assets: [{ name: 'HyperMug-1.9.0.zip' }] },
    { tag_name: 'v2.0.0', published_at: '2026-01-01', assets: [{ name: 'HyperMug-2.0.0.zip' }] },
    { tag_name: 'v2.1.0', published_at: '2026-03-01', assets: [] },
    { tag_name: 'v1.10.0', published_at: '2026-01-02', assets: [{ name: 'HyperMug-1.10.0.zip' }] },
  ];
  assert.deepEqual(productionVersions(history), ['2.0.0', '1.10.0', '1.9.0']);
  assert.equal(classify(body.replace('1.2.3', '2.0.0'), history), 'version:current');
  assert.equal(classify(body.replace('1.2.3', '2.1.0'), history), 'version:unverified');
});

test('API author controls access even when the event claims ownership', async () => {
  const calls = [];
  const request = async (method, path) => {
    calls.push([method, path]);
    return { number: 1, user: { login: 'someone-else' }, labels: [{ name: 'bug' }], body };
  };
  await triage({ event: { issue: { number: 1, user: { login: 'someone-else' }, labels: [{ name: 'bug' }], body: `${body}\n### Author\nmaxmeis` } }, repo: 'maxmeis/HyperMug', releasesRepo: 'maxmeis/HyperMug', request });
  await triage({ event: { issue: { number: 1, user: { login: 'maxmeis' }, labels: [{ name: 'bug' }], body } }, repo: 'maxmeis/HyperMug', releasesRepo: 'maxmeis/HyperMug', request });
  assert.deepEqual(calls, [['GET', '/repos/maxmeis/HyperMug/issues/1'], ['GET', '/repos/maxmeis/HyperMug/issues/1']]);
});

test('owner issue updates one existing bot comment only when content changes', async () => {
  const calls = [];
  const event = { issue: { number: 2, user: { login: 'maxmeis' }, labels: [{ name: 'bug' }, { name: 'needs-version' }], body: '### HyperMug marketing version\n_No response_' } };
  const wanted = missingComment(event.issue.body);
  const request = async (method, path, data) => {
    calls.push([method, path, data]);
    if (path === '/repos/maxmeis/HyperMug/issues/2') return event.issue;
    if (path.includes('/releases?')) return releases;
    if (path.includes('/comments?')) return [{ id: 5, body: wanted, user: { login: 'github-actions[bot]' } }];
    return null;
  };
  const args = { event, repo: 'maxmeis/HyperMug', releasesRepo: 'maxmeis/HyperMug', request };
  await triage(args);
  await triage(args);
  assert.equal(calls.filter(([method]) => method !== 'GET').length, 0);
});

test('owner issue creates one comment, updates it, and removes it when repaired', async () => {
  const comments = [];
  const calls = [];
  const event = { issue: { number: 3, user: { login: 'maxmeis' }, labels: [{ name: 'bug' }, { name: 'needs-version' }], body: '### HyperMug marketing version\n_No response_' } };
  const request = async (method, path, data) => {
    calls.push([method, path, data]);
    if (path === '/repos/maxmeis/HyperMug/issues/3') return event.issue;
    if (path.includes('/releases?')) return releases;
    if (path.includes('/comments?')) return [...comments];
    if (method === 'POST' && path.endsWith('/comments')) comments.push({ id: 10, body: data.body, user: { login: 'github-actions[bot]' } });
    if (method === 'PATCH') comments[0].body = data.body;
    if (method === 'DELETE' && path.includes('/comments/')) comments.length = 0;
    return null;
  };
  const args = { event, repo: 'maxmeis/HyperMug', releasesRepo: 'maxmeis/HyperMug', request };
  await triage(args);
  await triage(args);
  assert.equal(calls.filter(([method, path]) => method === 'POST' && path.endsWith('/comments')).length, 1);
  event.issue.body = '### HyperMug marketing version\n1.2.3';
  await triage(args);
  assert.equal(calls.filter(([method]) => method === 'PATCH').length, 1);
  event.issue.body = body;
  await triage(args);
  assert.equal(comments.length, 0);
  assert.equal(calls.filter(([method, path]) => method === 'DELETE' && path.includes('/comments/')).length, 1);
});

test('poll paginates, ignores pull requests and other authors, and reuses release lookup', async () => {
  const calls = [];
  const owner = { user: { login: 'maxmeis' }, labels: [{ name: 'bug' }, { name: 'version:older' }], body };
  const ignored = { ...owner, user: { login: 'someone-else' } };
  const request = async (method, path) => {
    calls.push([method, path]);
    if (path === '/user') return { login: 'triage-account' };
    if (path.includes('state=all')) return path.endsWith('page=1')
      ? [{ ...owner, number: 4 }, ...Array(99).fill(ignored)]
      : [{ ...owner, number: 5, pull_request: {} }, { ...owner, number: 6 }];
    if (path.endsWith('/issues/4')) return { ...owner, number: 4 };
    if (path.endsWith('/issues/6')) return { ...owner, number: 6 };
    if (path.includes('/releases?')) return releases;
    if (path.includes('/comments?')) return [];
    assert.fail(`Unexpected request: ${method} ${path}`);
  };

  await poll({ repo: 'maxmeis/hypermug', releasesRepo: 'maxmeis/hypermug', request });
  assert.equal(calls.filter(([, path]) => path.includes('state=all')).length, 2);
  assert.equal(calls.filter(([, path]) => path.includes('/releases?')).length, 1);
  assert.equal(calls.filter(([, path]) => path.includes('/comments?')).length, 2);
});

test('poll replaces an outdated Actions comment once and reuses the new token author comment', async () => {
  const issue = { number: 7, user: { login: 'maxmeis' }, labels: [{ name: 'bug' }, { name: 'needs-version' }], body: '' };
  let comments = [{ id: 1, user: { login: 'github-actions[bot]' }, body: missingComment('### HyperMug marketing version\n1.2.3') }];
  const writes = [];
  const request = async (method, path, data) => {
    if (path === '/user') return { login: 'triage-account' };
    if (path.includes('state=all')) return [issue];
    if (path.endsWith('/issues/7')) return issue;
    if (path.includes('/releases?')) return releases;
    if (path.includes('/comments?')) return comments;
    writes.push(method);
    if (method === 'DELETE' && path.endsWith('/comments/1')) comments = [];
    else if (method === 'POST' && path.endsWith('/issues/7/comments')) {
      comments.push({ id: 2, user: { login: 'triage-account' }, body: data.body });
    } else assert.fail(`Unexpected request: ${method} ${path}`);
  };
  const args = { repo: 'maxmeis/hypermug', releasesRepo: 'maxmeis/hypermug', request };
  await poll(args);
  await poll(args);
  assert.deepEqual(writes, ['DELETE', 'POST']);
  assert.equal(comments[0].body, missingComment(issue.body));
});
