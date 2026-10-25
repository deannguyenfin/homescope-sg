// Fair Price Check: the valuation drives a verdict and a negotiation plan.
// Checks the decision rules (cs_05 EstimateFairPrice) through the UI rather than
// fixed prices, so the test stays valid as new sales are synced.
// Requires synced data; set HOMESCOPE_EXPECT_DATA=0 to skip on an empty env.
import { test, expect } from '@playwright/test';

test.skip(process.env.HOMESCOPE_EXPECT_DATA === '0', 'environment has no synced data');

const money = s => Number(s.replace(/[^0-9.-]/g, ''));
const planValue = (page, label) =>
  page.getByText(label, { exact: true }).locator('xpath=ancestor::div[contains(@style,"justify-content")][1]').locator('[data-expression]').last();

async function readPlan(page) {
  const est = money(await page.getByText('Estimated fair value', { exact: true }).locator('xpath=following-sibling::div[1]').innerText());
  return {
    est,
    open: money(await planValue(page, 'Opening offer').innerText()),
    walk: money(await planValue(page, 'Walk-away price').innerText()),
    cov: money(await planValue(page, 'Cash over valuation (COV) at the asking price').innerText()),
  };
}

test('default flat: verdict, plan and evidence are shown', async ({ page }) => {
  await page.goto('FairPrice');
  await expect(page.getByText('Your negotiation plan')).toBeVisible({ timeout: 60_000 });
  await expect(page.getByText(/^(Below market value|Fairly priced|Above market value|Overpriced).*/).first()).toBeVisible();
  const p = await readPlan(page);
  const asking = 650000;
  expect(p.est).toBeGreaterThan(100000);
  expect(p.open).toBeLessThanOrEqual(p.est);          // open below fair value
  expect(p.walk).toBeLessThanOrEqual(asking);         // never walk away above the asking price
  expect(Math.abs(p.cov - Math.max(0, asking - p.est))).toBeLessThanOrEqual(1000); // COV = asking - valuation
  const rows = page.locator('table tbody tr');
  await expect(rows).toHaveCount(10);                 // 10 most similar sales
  // every column fits on desktop without horizontal scrolling
  const fits = await page.locator('table').evaluate(t => t.scrollWidth <= t.parentElement.clientWidth + 1);
  expect(fits).toBe(true);
});

test('a low asking price flips the verdict and removes COV', async ({ page }) => {
  await page.goto('FairPrice');
  await expect(page.getByText('Your negotiation plan')).toBeVisible({ timeout: 60_000 });
  const { est } = await readPlan(page);
  const asking = Math.round(est * 0.85 / 1000) * 1000; // 15% under fair value
  await page.locator('input').last().fill(String(asking));
  await page.getByRole('button', { name: 'Check this price' }).or(page.getByRole('link', { name: 'Check this price' })).first().click();
  await expect(page.getByText(`Asking S$ ${asking.toLocaleString('en-US')}`)).toBeVisible({ timeout: 60_000 });
  await expect(page.getByText(/^Below market value/).first()).toBeVisible();
  const p = await readPlan(page);
  expect(p.cov).toBe(0);
  expect(p.walk).toBeLessThanOrEqual(asking);
});
