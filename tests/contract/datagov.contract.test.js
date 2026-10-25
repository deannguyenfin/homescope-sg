// Contract tests for the upstream data.gov.sg datastore API consumed by the
// DataGov_IS module (REST "DataGovDatastore", method datastore_search).
// They fail fast if data.gov.sg changes the shape HomeScope's sync depends on.
import { test } from 'node:test';
import assert from 'node:assert/strict';

const BASE = process.env.DATAGOV_BASE_URL ?? 'https://data.gov.sg/api/action';
const RESOURCE_ID = process.env.RESALE_RESOURCE_ID ?? 'd_8b84c4ee58e3cfc0ece0d773c8ca6abc';
const headers = process.env.DATAGOV_API_KEY ? { 'x-api-key': process.env.DATAGOV_API_KEY } : {};

// Fields mapped by DataGov_IS.ResaleRecord (NameInJSON) -> Resale_CS.ResaleTransaction.
const REQUIRED_FIELDS = [
  'month', 'town', 'flat_type', 'block', 'street_name', 'storey_range',
  'floor_area_sqm', 'flat_model', 'lease_commence_date', 'remaining_lease', 'resale_price', '_id',
];

// The anonymous data.gov.sg tier is rate limited: pace calls and back off on 429
// (same policy the sync timer relies on via Site.MaxRetries).
const MIN_GAP_MS = Number(process.env.DATAGOV_MIN_GAP_MS ?? 3000);
let last = 0;
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function search(params) {
  const qs = new URLSearchParams({ resource_id: RESOURCE_ID, ...params });
  for (let attempt = 1; ; attempt++) {
    const wait = last + MIN_GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    const res = await fetch(`${BASE}/datastore_search?${qs}`, { headers });
    if (res.status === 429 && attempt < 5) { await sleep(5000 * attempt); continue; }
    if (res.status !== 200) {
      const detail = `HTTP ${res.status}: ${(await res.text()).slice(0, 300).replace(/s+/g, ' ')}`;
      if (process.env.GITHUB_ACTIONS) console.log(`::error title=data.gov.sg contract::${detail}`);
      assert.fail(detail);
    }
    return res.json();
  }
}

test('envelope: success flag, result object, total and limit', async () => {
  const body = await search({ limit: '5' });
  assert.equal(body.success, true);
  assert.equal(body.result.resource_id, RESOURCE_ID);
  assert.equal(body.result.limit, 5);
  assert.ok(Number.isInteger(body.result.total) && body.result.total > 200000, `total=${body.result.total}`);
  assert.equal(body.result.records.length, 5);
});

test('schema: every field the sync maps is present', async () => {
  const body = await search({ limit: '1' });
  const ids = body.result.fields.map(f => f.id);
  for (const f of REQUIRED_FIELDS) assert.ok(ids.includes(f), `missing field ${f}`);
  const rec = body.result.records[0];
  for (const f of REQUIRED_FIELDS) assert.ok(f in rec, `record missing ${f}`);
});

test('values: formats the typed conversion in Resale_CS relies on', async () => {
  const { result } = await search({ limit: '50' });
  for (const r of result.records) {
    assert.match(r.month, /^\d{4}-\d{2}$/, 'month is YYYY-MM');
    assert.match(String(r.resale_price), /^\d+(\.\d+)?$/, 'resale_price numeric text');
    assert.match(String(r.floor_area_sqm), /^\d+(\.\d+)?$/, 'floor_area_sqm numeric text');
    assert.match(String(r.lease_commence_date), /^\d{4}$/, 'lease_commence_date is a year');
    assert.match(r.storey_range, /^\d{2} TO \d{2}$/, 'storey_range "NN TO NN"');
    assert.match(r.remaining_lease, /^\d+ years?( \d+ months?)?$/, 'remaining_lease "N years M months"');
    assert.ok(r.town.length > 0 && r.flat_type.length > 0);
  }
});

test('paging: offset is stable and contiguous by _id (incremental sync contract)', async () => {
  const a = await search({ limit: '10', offset: '0', sort: '_id asc' });
  const b = await search({ limit: '10', offset: '10', sort: '_id asc' });
  const ids = [...a.result.records, ...b.result.records].map(r => r._id);
  for (let i = 1; i < ids.length; i++) assert.equal(ids[i], ids[i - 1] + 1, `gap at ${ids[i - 1]} -> ${ids[i]}`);
});

test('filters: JSON filters narrow by town and flat type', async () => {
  const filters = JSON.stringify({ town: 'TAMPINES', flat_type: '4 ROOM' });
  const { result } = await search({ limit: '20', filters });
  assert.ok(result.records.length > 0);
  for (const r of result.records) { assert.equal(r.town, 'TAMPINES'); assert.equal(r.flat_type, '4 ROOM'); }
});
