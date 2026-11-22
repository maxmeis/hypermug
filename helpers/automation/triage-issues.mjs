import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export const MARKER = '<!-- hypermug-version-triage -->';
export const MANAGED_LABELS = ['needs-version', 'version:current', 'version:older', 'version:unverified', 'version:local'];

export function field(body, label) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = body.match(new RegExp(`(?:^|\\n)### ${escaped}\\s*\\n([\\s\\S]*?)(?=\\n### |$)`, 'i'));
  const value = match?.[1]?.trim() ?? '';
  return value === '_No response_' ? '' : value;
}

export function reportedVersion(body) {
  const marketing = field(body, 'HyperMug marketing version');
  const build = field(body, 'HyperMug build number');
  const validMarketing = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(marketing);
  const validBuild = /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/.test(build);
  return { marketing, build, complete: validMarketing && validBuild };
}

export function productionVersions(releases) {
  return releases.filter(r => {
    if (r.draft || r.prerelease || !/^v\d+\.\d+\.\d+$/.test(r.tag_name)) return false;
    // Source-only GitHub Releases are valid versions, but cannot be an
    // installed production app or make an older binary "outdated".
    return r.assets?.some(asset => asset.name === `HyperMug-${r.tag_name.slice(1)}.zip`);
  })
    .sort((a, b) => {
      const left = a.tag_name.slice(1).split('.').map(BigInt);
      const right = b.tag_name.slice(1).split('.').map(BigInt);
      for (let i = 0; i < 3; i++) {
        if (left[i] !== right[i]) return left[i] < right[i] ? 1 : -1;
      }
      return 0;
    })
    .map(r => r.tag_name.slice(1));
}

export function classify(body, releases) {
  const report = reportedVersion(body);
  if (!report.complete) return 'needs-version';
  if (field(body, 'Install source') === 'Built from source') return 'version:local';
  if (releases === null) return null;
  const versions = productionVersions(releases);
  if (!versions.length || !versions.includes(report.marketing)) return 'version:unverified';
  return report.marketing === versions[0] ? 'version:current' : 'version:older';
}

export function missingComment(body) {
  const { marketing, build, complete } = reportedVersion(body);
  if (complete) return null;
  const missing = [!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(marketing) && 'marketing version', !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/.test(build) && 'build number'].filter(Boolean).join(' and ');
  return `${MARKER}\nThanks for the report. Please add the exact installed HyperMug ${missing} from CFBundleShortVersionString and CFBundleVersion in the app bundle's Info.plist. The marketing version should look like 1.2.3 (a local build may have a suffix); enter the build exactly as shown. For an app in /Applications, run:\n\n\`/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/HyperMug.app/Contents/Info.plist\`\n\`/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/HyperMug.app/Contents/Info.plist\`\n\nOlder releases and local builds are welcome; please report their actual values.`;
}

export async function triage({ event, repo, releasesRepo, request, commentAuthor = 'github-actions[bot]' }) {
  const issueNumber = event.issue?.number;
  if (!Number.isSafeInteger(issueNumber) || issueNumber < 1) return;
  // The issue endpoint is the authority for both author and current content.
  // An edited-event payload can already be stale when this job starts.
  const issue = await request('GET', `/repos/${repo}/issues/${issueNumber}`);
  if (issue.pull_request || issue.user?.login !== 'maxmeis' || !issue.labels?.some(l => l.name === 'bug')) return;
  let releases = null;
  try { releases = await request('GET', `/repos/${releasesRepo}/releases?per_page=100`); }
  catch (error) { console.warn(`Release lookup unavailable: ${error.message}`); }
  const label = classify(issue.body || '', releases);
  const existing = issue.labels.map(l => l.name);
  if (label) for (const old of MANAGED_LABELS.filter(l => l !== label && existing.includes(l))) {
    await request('DELETE', `/repos/${repo}/issues/${issue.number}/labels/${encodeURIComponent(old)}`);
  }
  if (label && !existing.includes(label)) {
    try { await request('POST', `/repos/${repo}/labels`, { name: label, color: 'd4c5f9', description: 'HyperMug reported version triage' }); }
    catch (error) { if (error.status !== 422) throw error; }
    await request('POST', `/repos/${repo}/issues/${issue.number}/labels`, { labels: [label] });
  }
  let bot;
  for (let page = 1; !bot; page++) {
    const comments = await request('GET', `/repos/${repo}/issues/${issue.number}/comments?per_page=100&page=${page}`);
    bot = comments.find(c => c.body?.startsWith(MARKER) &&
      [commentAuthor, 'github-actions[bot]'].includes(c.user?.login));
    if (comments.length < 100) break;
  }
  const wanted = missingComment(issue.body || '');
  if (wanted && bot?.body === wanted) return;
  if (bot && wanted && bot.user.login === commentAuthor) {
    await request('PATCH', `/repos/${repo}/issues/comments/${bot.id}`, { body: wanted });
    return;
  }
  if (bot) await request('DELETE', `/repos/${repo}/issues/comments/${bot.id}`);
  if (wanted) await request('POST', `/repos/${repo}/issues/${issue.number}/comments`, { body: wanted });
}

export async function poll({ repo, releasesRepo, request }) {
  const { login: commentAuthor } = await request('GET', '/user');
  if (!commentAuthor) throw new Error('Could not identify the triage token owner');
  const releasesPath = `/repos/${releasesRepo}/releases?per_page=100`;
  let releaseLookup;
  const pollRequest = (method, endpoint, data) => {
    if (method === 'GET' && endpoint === releasesPath) return releaseLookup ??= request(method, endpoint);
    return request(method, endpoint, data);
  };
  for (let page = 1; ; page++) {
    const issues = await request('GET', `/repos/${repo}/issues?state=all&creator=maxmeis&labels=bug&sort=created&direction=asc&per_page=100&page=${page}`);
    for (const issue of issues) {
      if (issue.pull_request || issue.user?.login !== 'maxmeis') continue;
      await triage({ event: { issue: { number: issue.number } }, repo, releasesRepo, request: pollRequest, commentAuthor });
    }
    if (issues.length < 100) return;
  }
}

async function main() {
  const { GITHUB_TOKEN: token, GITHUB_EVENT_PATH: path, GITHUB_REPOSITORY: repo = process.env.CI_REPO, RELEASES_REPOSITORY: releasesRepo = repo } = process.env;
  const polling = process.argv[2] === '--poll';
  const repoPattern = /^[\w.-]+\/[\w.-]+$/;
  if (!token || (!polling && !path) || !repoPattern.test(repo ?? '') || !repoPattern.test(releasesRepo ?? '')) throw new Error('Missing or invalid workflow environment');
  const request = async (method, endpoint, data) => {
    const response = await fetch(`https://api.github.com${endpoint}`, { method, headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', ...(data && { 'Content-Type': 'application/json' }) }, body: data && JSON.stringify(data) });
    if (!response.ok) { const error = new Error(`GitHub API ${response.status} for ${method} ${endpoint}`); error.status = response.status; throw error; }
    return response.status === 204 ? null : response.json();
  };
  if (polling) await poll({ repo, releasesRepo, request });
  else await triage({ event: JSON.parse(await readFile(path, 'utf8')), repo, releasesRepo, request });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => { console.error(error); process.exitCode = 1; });
