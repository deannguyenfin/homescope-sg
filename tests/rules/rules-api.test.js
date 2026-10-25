// Business-rule tests against the deployed Resale_CS RulesAPI (REST, exposed for CI).
// The same server actions (ClassifyVerdict, CalculateAffordability, UpsertResalePage)
// back the HomeScope screens, so these tests exercise production logic, not a copy.
// OutSystems omits default values (0 / false / "") from REST JSON, so missing = default.
import { test } from 'node:test';
import assert from 'node:assert/strict';

const ORIGIN = new URL(process.env.HOMESCOPE_URL ?? 'https://personal-ljonxgvs.outsystemscloud.com/HomeScope/').origin;
const API = `${ORIGIN}/Resale_CS/rest/RulesAPI`;

async function call(method, path, params = {}) {
  const qs = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]));
  const res = await fetch(`${API}/${path}?${qs}`, { method, headers: method === 'POST' ? { 'Content-Length': '0' } : {} });
  const body = await res.json();
  return { status: res.status, body };
}
const num = (o, k) => o[k] ?? 0;

// ---- Verdict: gap = (asking - estimate) / estimate; BELOW <= -5% < FAIR <= 5% < ABOVE <= 10% < OVER ----
const base = { EstimatedPrice: 500000, FairLow: 480000, FairHigh: 520000, SpreadPct: 10, Comparables: 25 };
const verdict = asking => call('GET', 'Verdict', { ...base, AskingPrice: asking }).then(r => r.body);

test('verdict thresholds at the -5 / 5 / 10 % boundaries', async () => {
  const cases = [[470000, 'BELOW'], [475000, 'BELOW'], [476000, 'FAIR'], [500000, 'FAIR'], [525000, 'FAIR'],
    [526000, 'ABOVE'], [550000, 'ABOVE'], [551000, 'OVER']];
  for (const [asking, expected] of cases) {
    const v = await verdict(asking);
    assert.equal(v.Verdict, expected, `asking ${asking} -> gap ${num(v, 'PriceGapPct')}%`);
  }
});

test('fewer than 5 comparables gives NODATA', async () => {
  const { body } = await call('GET', 'Verdict', { ...base, Comparables: 4, AskingPrice: 500000 });
  assert.equal(body.Verdict, 'NODATA');
});

test('confidence depends on comparables and spread', async () => {
  const conf = async (Comparables, SpreadPct) => (await call('GET', 'Verdict', { ...base, Comparables, SpreadPct, AskingPrice: 500000 })).body.Confidence;
  assert.equal(await conf(20, 15), 'High');
  assert.equal(await conf(19, 15), 'Medium');
  assert.equal(await conf(25, 16), 'Medium');
  assert.equal(await conf(10, 25), 'Medium');
  assert.equal(await conf(9, 10), 'Low');
  assert.equal(await conf(25, 30), 'Low');
});

test('negotiation guidance: opening offer, walk-away and cash over valuation', async () => {
  const v = await verdict(530000);
  assert.equal(num(v, 'PriceGapPct'), 6);
  assert.equal(num(v, 'OpeningOffer'), 490000);       // midpoint of fair low and estimate, to the nearest 1,000
  assert.equal(num(v, 'WalkAwayPrice'), 520000);      // top of fair range
  assert.equal(num(v, 'CashOverValuation'), 30000);   // asking above estimate
  const cheap = await verdict(450000);
  assert.equal(num(cheap, 'OpeningOffer'), 450000);   // never above asking
  assert.equal(num(cheap, 'WalkAwayPrice'), 450000);
  assert.equal(num(cheap, 'CashOverValuation'), 0);
});

// ---- Affordability: standard annuity, MSR cap 30% of gross monthly income ----
test('affordability matches the annuity formula and MSR cap', async () => {
  const p = { Price: 500000, DownPaymentPct: 25, AnnualInterestPct: 2.6, TenureYears: 25, GrossMonthlyIncome: 8000 };
  const { status, body } = await call('GET', 'Affordability', p);
  assert.equal(status, 200);
  const loan = p.Price * (1 - p.DownPaymentPct / 100);
  const r = p.AnnualInterestPct / 1200, n = p.TenureYears * 12;
  const pmt = loan * r / (1 - (1 + r) ** -n);
  assert.equal(num(body, 'DownPayment'), 125000);
  assert.equal(num(body, 'LoanAmount'), loan);
  assert.ok(Math.abs(num(body, 'MonthlyInstalment') - pmt) < 0.01, `instalment ${body.MonthlyInstalment} vs ${pmt}`);
  assert.ok(Math.abs(num(body, 'MsrPct') - pmt / p.GrossMonthlyIncome * 100) < 0.01);
  const maxPrice = (0.3 * p.GrossMonthlyIncome) * (1 - (1 + r) ** -n) / r / (1 - p.DownPaymentPct / 100);
  assert.ok(Math.abs(num(body, 'MaxAffordablePrice') - maxPrice) < 5, `max ${body.MaxAffordablePrice} vs ${maxPrice}`);
  assert.equal(body.WithinMsr ?? false, true);

  const tight = (await call('GET', 'Affordability', { ...p, GrossMonthlyIncome: 5000 })).body;
  assert.equal(tight.WithinMsr ?? false, false);       // 1,701 / 5,000 = 34% > 30%
});

test('zero interest is a straight-line repayment', async () => {
  const { body } = await call('GET', 'Affordability', { Price: 360000, DownPaymentPct: 0, AnnualInterestPct: 0, TenureYears: 30, GrossMonthlyIncome: 5000 });
  assert.equal(num(body, 'MonthlyInstalment'), 1000);
  assert.equal(num(body, 'TotalInterest'), 0);
});

test('invalid inputs are rejected with InvalidInput', async () => {
  const bad = [
    { Price: 0, DownPaymentPct: 25, AnnualInterestPct: 2.6, TenureYears: 25, GrossMonthlyIncome: 8000 },
    { Price: 500000, DownPaymentPct: 120, AnnualInterestPct: 2.6, TenureYears: 25, GrossMonthlyIncome: 8000 },
    { Price: 500000, DownPaymentPct: 25, AnnualInterestPct: 2.6, TenureYears: 40, GrossMonthlyIncome: 8000 },
  ];
  for (const p of bad) {
    const { status, body } = await call('GET', 'Affordability', p);
    assert.equal(status, 500, JSON.stringify(p));
    assert.ok(body.Errors?.length, 'error message returned');
  }
});

// ---- Sync: set-based upsert is idempotent and detects changes (runs in a rolled-back transaction) ----
test('sync self-test: insert, idempotent replay, change detection', async (t) => {
  const { status, body } = await call('POST', 'SyncSelfTest');
  if (status === 500 && /not authori[sz]ed/i.test(body.Errors?.[0] ?? '')) return t.skip('EnableSelfTest is off in this environment');
  assert.equal(status, 200);
  assert.equal(num(body, 'FirstInserted'), 2);
  assert.equal(num(body, 'ChangedUpdated'), 1);
  assert.equal(num(body, 'Rows'), 2);
  assert.equal(body.Passed ?? false, true);
});
