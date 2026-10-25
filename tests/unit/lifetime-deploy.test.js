// Unit tests for the promotion script against a mocked LifeTime Deployment API.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { run, parseArgs } from '../../scripts/lifetime-deploy.mjs';

const env = { LIFETIME_URL: 'https://lt.example/', LIFETIME_TOKEN: 't' };
const APPS = 'HomeScope Services,HomeScope';

// In-memory LifeTime: Development, Test, Production and two apps.
function fakeLifeTime({ versions = {}, running = {}, statuses = ['running', 'finished_successful'] } = {}) {
  const calls = [];
  const st = [...statuses];
  const fetch = async (url, { method, body }) => {
    const path = url.replace('https://lt.example/lifetimeapi/rest/v2', '');
    calls.push(`${method} ${path.split('?')[0]}`);
    const json = v => ({ ok: true, status: 200, text: async () => JSON.stringify(v) });
    if (path === '/environments') return json([{ Name: 'Development', Key: 'dev' }, { Name: 'Test', Key: 'tst' }, { Name: 'Production', Key: 'prd' }]);
    if (path === '/applications') return json([{ Name: 'HomeScope Services', Key: 'svc' }, { Name: 'HomeScope', Key: 'ui' }]);
    let m;
    if ((m = path.match(/^\/applications\/(\w+)\/versions$/))) return json(versions[m[1]] ?? []);
    if ((m = path.match(/^\/environments\/(\w+)\/applications\/(\w+)\?/))) return json({ AppStatusInEnvs: [{ EnvironmentKey: m[1], ...(running[`${m[1]}/${m[2]}`] ?? {}) }] });
    if ((m = path.match(/^\/environments\/(\w+)\/applications\/(\w+)\/versions$/)) && method === 'POST') return json({ Key: `${m[2]}-${JSON.parse(body).Version}` });
    if (path === '/deployments' && method === 'POST') return json('plan-1');
    if (path === '/deployments/plan-1/start') return { ok: true, status: 202, text: async () => '' };
    if (path === '/deployments/plan-1/status') return json({ DeploymentStatus: st.shift(), DeploymentLog: [] });
    return { ok: false, status: 404, text: async () => 'not found' };
  };
  return { fetch, calls };
}
const deps = f => ({ env, fetch: f.fetch, wait: async () => {}, log: () => {}, pollMs: 0 });

test('parseArgs handles values and boolean flags', () => {
  assert.deepEqual(parseArgs(['--from', 'Test', '--tag', '--version', '1.0.3', '--allow-warnings']),
    { from: 'Test', tag: true, version: '1.0.3', 'allow-warnings': true });
});

test('first promotion tags each app in Development, Services first, and deploys', async () => {
  const lt = fakeLifeTime();
  const r = await run({ from: 'Development', to: 'Test', apps: APPS, version: '1.0.3', tag: true }, deps(lt));
  assert.deepEqual(r.ops.map(o => o.VersionKey), ['svc-1.0.3', 'ui-1.0.3']);
  assert.ok(lt.calls.indexOf('POST /deployments/plan-1/start') > lt.calls.indexOf('POST /deployments'));
});

test('promotion to Production deploys the version running unmodified in Test', async () => {
  const lt = fakeLifeTime({
    versions: { svc: [{ Version: '1.0.3', Key: 'v-svc' }], ui: [{ Version: '1.0.3', Key: 'v-ui' }] },
    running: { 'tst/svc': { BaseApplicationVersionKey: 'v-svc', IsModified: false }, 'tst/ui': { BaseApplicationVersionKey: 'v-ui', IsModified: false } },
  });
  const r = await run({ from: 'Test', to: 'Production', apps: APPS, version: '1.0.3' }, deps(lt));
  assert.deepEqual(r.ops.map(o => o.VersionKey), ['v-svc', 'v-ui']);
  assert.ok(!lt.calls.some(c => c.startsWith('POST /environments')), 'nothing is tagged on the way to Production');
});

test('refuses Production when Test runs a different or modified version', async () => {
  const lt = fakeLifeTime({
    versions: { svc: [{ Version: '1.0.3', Key: 'v-svc' }] },
    running: { 'tst/svc': { BaseApplicationVersionKey: 'v-svc', IsModified: true } },
  });
  await assert.rejects(run({ from: 'Test', to: 'Production', apps: APPS, version: '1.0.3' }, deps(lt)), /not what runs unmodified in Test/);
  assert.ok(!lt.calls.includes('POST /deployments'));
});

test('refuses an untagged version without --tag', async () => {
  await assert.rejects(run({ from: 'Test', to: 'Production', apps: APPS, version: '9.9.9' }, deps(fakeLifeTime())), /does not exist/);
});

test('finished_with_warnings fails unless --allow-warnings', async () => {
  const args = { from: 'Development', to: 'Test', apps: APPS, version: '1.0.4', tag: true };
  await assert.rejects(run(args, deps(fakeLifeTime({ statuses: ['finished_with_warnings'] }))), /finished with warnings/);
  await run({ ...args, 'allow-warnings': true }, deps(fakeLifeTime({ statuses: ['finished_with_warnings'] })));
});

test('errors and aborts fail the run', async () => {
  const args = { from: 'Development', to: 'Test', apps: APPS, version: '1.0.5', tag: true };
  for (const s of ['finished_with_errors', 'aborted', 'needs_user_intervention']) {
    await assert.rejects(run(args, deps(fakeLifeTime({ statuses: [s] }))), new RegExp(s));
  }
});

test('missing configuration is rejected before any call', async () => {
  await assert.rejects(run({ from: 'A' }, { env: {}, fetch: () => assert.fail('no call') }), /LIFETIME_URL/);
});
