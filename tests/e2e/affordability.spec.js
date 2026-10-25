// Business rule checks for Resale_CS.CalculateAffordability through the UI.
// Expected values are computed independently with the standard annuity
// formula: instalment = L * r / (1 - (1 + r)^-n), r = annual% / 12, n = years * 12.
import { test, expect } from '@playwright/test';

function annuity(price, dpPct, ratePct, years) {
  const loan = price * (1 - dpPct / 100);
  const r = ratePct / 100 / 12, n = years * 12;
  return Math.round(loan * (r === 0 ? 1 / n : r / (1 - Math.pow(1 + r, -n))) * 100) / 100;
}
const sgd = v => 'S$ ' + Math.round(v).toLocaleString('en-US');

test('default scenario: S$500k, 25% down, 2.6%, 25y, S$8k income', async ({ page }) => {
  await page.goto('Affordability');
  const inst = annuity(500000, 25, 2.6, 25); // 1701.26
  await expect(page.getByText(sgd(inst), { exact: true }).first()).toBeVisible();
  const msr = (inst * 100 / 8000).toFixed(1); // 21.3
  await expect(page.getByText(`Within the 30% MSR limit (${msr}% of income)`)).toBeVisible();
});

test('low income breaches the 30% MSR cap', async ({ page }) => {
  await page.goto('Affordability');
  const income = page.locator('input').nth(4); // Price, Down %, Rate, Tenure, Income
  await income.fill('4000');
  await page.getByRole('link', { name: 'Calculate' }).or(page.getByRole('button', { name: 'Calculate' })).first().click();
  const msr = (annuity(500000, 25, 2.6, 25) * 100 / 4000).toFixed(1); // 42.5
  await expect(page.getByText(`Exceeds the 30% MSR limit (${msr}% of income)`)).toBeVisible();
});

test('zero interest falls back to straight-line repayment', async ({ page }) => {
  await page.goto('Affordability');
  await page.locator('input').nth(2).fill('0');
  await page.getByRole('link', { name: 'Calculate' }).or(page.getByRole('button', { name: 'Calculate' })).first().click();
  await expect(page.getByText(sgd(375000 / 300), { exact: true }).first()).toBeVisible(); // S$ 1,250
});
