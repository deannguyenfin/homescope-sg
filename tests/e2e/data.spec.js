// Data exploration flows. Requires a completed sync (Admin > Sync now, or the
// nightly SyncResaleTimer). Set HOMESCOPE_EXPECT_DATA=0 to skip on an empty env.
import { test, expect } from '@playwright/test';

test.skip(process.env.HOMESCOPE_EXPECT_DATA === '0', 'environment has no synced data');

const num = t => Number(String(t).replace(/[^0-9.]/g, ''));

test('Dashboard: KPIs populated and both charts drawn', async ({ page }) => {
  await page.goto('Dashboard');
  const total = page.locator('text=TRANSACTIONS ON RECORD').locator('xpath=following-sibling::*[1]');
  await expect.poll(async () => num(await total.innerText())).toBeGreaterThan(100000);
  await expect(page.locator('.highcharts-container')).toHaveCount(2);
  await expect(page.locator('.highcharts-series path, .highcharts-series rect').first()).toBeVisible();
});

test('Dashboard: town filter narrows the KPIs', async ({ page }) => {
  await page.goto('Dashboard');
  const total = page.locator('text=TRANSACTIONS ON RECORD').locator('xpath=following-sibling::*[1]');
  await expect.poll(async () => num(await total.innerText())).toBeGreaterThan(0);
  const all = num(await total.innerText());
  await page.locator('select').first().selectOption({ label: 'TAMPINES' });
  await expect.poll(async () => num(await total.innerText())).toBeLessThan(all);
});

test('Explore: table, search, sort and pagination', async ({ page }) => {
  await page.goto('Explore');
  const rows = page.locator('table tbody tr');
  await expect(rows).toHaveCount(20);

  await page.getByRole('searchbox').or(page.locator('input[type="search"], input').first()).first().fill('TAMPINES ST');
  await expect.poll(async () => (await rows.allInnerTexts()).every(r => r.includes('TAMPINES ST'))).toBe(true);

  await page.getByText('Clear filters').click();
  await expect(rows).toHaveCount(20);

  // Sort by price (header click toggles asc/desc via OnSort -> TableSort).
  await page.locator('th', { hasText: 'Price' }).first().click();
  const prices = async () => (await page.locator('table tbody tr td:last-child').allInnerTexts()).map(num);
  await expect.poll(async () => { const p = await prices(); return p.every((v, i) => i === 0 || p[i - 1] <= v); }).toBe(true);

  const firstRow = await rows.first().innerText();
  await page.locator('.pagination-button, [class*="pagination"] button').last().click();
  await expect.poll(async () => rows.first().innerText()).not.toBe(firstRow);
});

test('Towns: one bar per town and a sortable stats table', async ({ page }) => {
  await page.goto('Towns');
  const rows = page.locator('table tbody tr');
  await expect.poll(async () => rows.count()).toBeGreaterThanOrEqual(25); // 26 HDB towns
  await expect(page.locator('.highcharts-container')).toHaveCount(1);
  await page.locator('select').first().selectOption({ label: '4 ROOM' });
  await expect.poll(async () => rows.count()).toBeGreaterThanOrEqual(20);
});
