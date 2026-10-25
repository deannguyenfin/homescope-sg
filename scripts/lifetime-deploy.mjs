#!/usr/bin/env node
// Promote OutSystems applications between environments with the LifeTime
// Deployment API v2 (self-managed infrastructure provisioned by infra/terraform).
//
//   LIFETIME_URL=https://lifetime.example.com LIFETIME_TOKEN=<service account token> \
//   node scripts/lifetime-deploy.mjs --from Development --to Production \
//        --apps "HomeScope Services,HomeScope" --version 1.0.3 --notes "Release 1.0.3"
//
// Steps: resolve env/app keys -> tag a version of each app in the source env
// (Services first, so the deployment plan respects the 3-layer dependencies)
// -> create a deployment plan -> start it -> poll until finished.

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1]]);
  return acc;
}, []));

const BASE = `${process.env.LIFETIME_URL?.replace(/\/$/, '')}/lifetimeapi/rest/v2`;
const TOKEN = process.env.LIFETIME_TOKEN;
if (!process.env.LIFETIME_URL || !TOKEN) throw new Error('LIFETIME_URL and LIFETIME_TOKEN are required');
for (const k of ['from', 'to', 'apps', 'version']) if (!args[k]) throw new Error(`--${k} is required`);

async function lt(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

const envs = await lt('GET', '/environments');
const envKey = name => {
  const e = envs.find(x => x.Name === name);
  if (!e) throw new Error(`environment "${name}" not found`);
  return e.Key;
};
const source = envKey(args.from);
const target = envKey(args.to);

const allApps = await lt('GET', '/applications');
const ops = [];
for (const name of args.apps.split(',').map(s => s.trim())) {
  const app = allApps.find(a => a.Name === name);
  if (!app) throw new Error(`application "${name}" not found`);
  // Tag the current running version in the source environment.
  const tagged = await lt('POST', `/environments/${source}/applications/${app.Key}/versions`, {
    ChangeLog: args.notes ?? `Release ${args.version}`,
    Version: args.version,
    MobileVersions: [],
  });
  console.log(`tagged ${name} ${args.version} (${tagged.Key ?? tagged.ApplicationVersionKey})`);
  ops.push({ ApplicationKey: app.Key, VersionKey: tagged.Key ?? tagged.ApplicationVersionKey });
}

const plan = await lt('POST', '/deployments', {
  ApplicationOperations: ops,
  Notes: args.notes ?? `HomeScope ${args.version} via GitHub Actions`,
  SourceEnvironmentKey: source,
  TargetEnvironmentKey: target,
});
const key = typeof plan === 'string' ? plan : plan.Key;
console.log(`deployment plan ${key} created`);

await lt('POST', `/deployments/${key}/start`);
const deadline = Date.now() + 45 * 60_000;
for (;;) {
  const st = await lt('GET', `/deployments/${key}/status`);
  console.log(`status: ${st.DeploymentStatus}`);
  if (['finished_successful'].includes(st.DeploymentStatus)) break;
  if (['finished_with_errors', 'aborted', 'needs_user_intervention'].includes(st.DeploymentStatus) || Date.now() > deadline) {
    throw new Error(`deployment ${key} ended as ${st.DeploymentStatus}: ${JSON.stringify(st.DeploymentLog ?? [])}`);
  }
  await new Promise(r => setTimeout(r, 15_000));
}
console.log('deployment finished successfully');
