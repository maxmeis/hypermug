import { fileURLToPath } from 'node:url';

const plugin = fileURLToPath(new URL('./helpers/semantic_plugins.mjs', import.meta.url));

// The queue supplies a single source SHA and an isolated, local Git remote. The
// production publisher owns tags and assets after the signed archive is ready.
export function releaseConfig(sourceSha, repositoryUrl) {
  if (!/^[0-9a-f]{40}$/.test(sourceSha ?? '')) throw new Error('RELEASE_SOURCE_SHA is required');
  if (!repositoryUrl) throw new Error('RELEASE_REPOSITORY_URL is required');
  return {
    branches: ['main'],
    repositoryUrl,
    tagFormat: 'v${version}',
    plugins: [[plugin, { sourceSha }]],
  };
}

export default process.env.RELEASE_SOURCE_SHA && process.env.RELEASE_REPOSITORY_URL
  ? releaseConfig(process.env.RELEASE_SOURCE_SHA, process.env.RELEASE_REPOSITORY_URL)
  : { branches: [], repositoryUrl: 'file:///dev/null', plugins: [[plugin, { sourceSha: '' }]] };
