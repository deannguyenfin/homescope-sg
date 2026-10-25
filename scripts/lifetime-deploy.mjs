#!/usr/bin/env node
// Promote OutSystems applications between environments with the LifeTime
// Deployment API v2 (self-managed infrastructure provisioned by infra/terraform).
//
//   First promotion (Development -> Test): tag what runs in Development.
//     node scripts/lifetime-deploy.mjs --from Development --to Test --tag \
//          --apps "HomeScope Services,HomeScope" --version 1.0.3
//   Later promotions (Test -> Production): deploy only the version that is
//   already running, unmodified, in Test. Nothing is tagged.
//     node scripts/lifetime-deploy.mjs --from Test --to Production \
//          --apps "HomeScope Services,HomeScope" --version 1.0.3
//
// Env: LIFETIME_URL, LIFETIME_TOKEN (service account). Flags: --notes,
// --allow-warnings (finished_with_warnings fails the run unless set),
// --timeout-min (default 45).
//
// Apps are listed Services first, so the plan respects the 3-layer dependencies.

import { pathToFileURL } from "node:url";

const sleep = ms => new Promise(r => setTimeout(r, ms));

export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const k = argv[i].slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[k] = true;
    else { out[k] = next; i++; }
  }
  return out;
}

export async function run(args, { env = process.env, fetch = globalThis.fetch, wait = sleep, log = console.log, pollMs = 15_000 } = {}) {
  if (!env.LIFETIME_URL || !env.LIFETIME_TOKEN) throw new Error('LIFETIME_URL and LIFETIME_TOKEN are required');
  for (const k of ['from', 'to', 'apps', 'version']) if (!args[k] || args[k] === true) throw new Error(`--${k} is required`);
  const base = `${env.LIFETIME_URL.replace(/\/$/, '')}/lifetimeapi/rest/v2`;

  async function lt(method, path, body) {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { Authorization: `Bearer ${env.LIFETIME_TOKEN}`, 'Content-Type': 'application/json' },
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
  const notes = args.notes && args.notes !== true ? args.notes : `HomeScope ${args.version}`;

  const allApps = await lt('GET', '/applications');
  const ops = [];
  for (const name of args.apps.split(',').map(s => s.trim()).filter(Boolean)) {
    const app = allApps.find(a => a.Name === name);
    if (!app) throw new Error(`application "${name}" not found`);

    const versions = (await lt('GET', `/applications/${app.Key}/versions`)) ?? [];
    const existing = versions.find(v => v.Version === args.version);
    const detail = await lt('GET', `/environments/${source}/applications/${app.Key}?IncludeEnvStatus=true`);
    const inSource = (detail?.AppStatusInEnvs ?? []).find(s => s.EnvironmentKey === source);

    let versionKey;
    if (existing) {
      // Promote exactly what was tested: the version must be what runs in the
      // source environment, with no changes published on top of it.
      if (!inSource || inSource.BaseApplicationVersionKey !== existing.Key || inSource.IsModified) {
        throw new Error(`${name} ${args.version} is not what runs unmodified in ${args.from}; promote from the environment where it was tested`);
      }
      versionKey = existing.Key;
      log(`${name} ${args.version} verified in ${args.from}`);
    } else {
      if (!args.tag) throw new Error(`${name} ${args.version} does not exist; tag it in the first promotion (--tag)`);
      const tagged = await lt('POST', `/environments/${source}/applications/${app.Key}/versions`, {
        ChangeLog: notes, Version: args.version, MobileVersions: [],
      });
      versionKey = typeof tagged === 'string' ? tagged : (tagged.Key ?? tagged.ApplicationVersionKey);
      log(`tagged ${name} ${args.version} (${versionKey})`);
    }
    ops.push({ ApplicationKey: app.Key, VersionKey: versionKey });
  }

  const plan = await lt('POST', '/deployments', {
    ApplicationOperations: ops, Notes: notes, SourceEnvironmentKey: source, TargetEnvironmentKey: target,
  });
  const key = typeof plan === 'string' ? plan : plan.Key;
  log(`deployment plan ${key} created (${args.from} -> ${args.to})`);

  await lt('POST', `/deployments/${key}/start`);
  const deadline = Date.now() + Number(args['timeout-min'] ?? 45) * 60_000;
  for (;;) {
    const st = await lt('GET', `/deployments/${key}/status`);
    const s = st.DeploymentStatus;
    log(`status: ${s}`);
    if (s === 'finished_successful') break;
    if (s === 'finished_with_warnings') {
      log(JSON.stringify(st.DeploymentLog ?? []));
      if (args['allow-warnings']) break;
      throw new Error(`deployment ${key} finished with warnings (rerun with --allow-warnings after review)`);
    }
    if (['finished_with_errors', 'aborted', 'needs_user_intervention'].includes(s)) {
      throw new Error(`deployment ${key} ended as ${s}: ${JSON.stringify(st.DeploymentLog ?? [])}`);
    }
    if (Date.now() > deadline) throw new Error(`deployment ${key} still ${s} after the timeout`);
    await wait(pollMs);
  }
  log('deployment finished');
  return { key, ops };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run(parseArgs(process.argv.slice(2))).catch(e => { console.error(e.message); process.exit(1); });
}
