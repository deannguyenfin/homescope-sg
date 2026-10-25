// Smoke (signed in as a standard user): every screen renders, navigation works,
// Admin is protected; anonymous visitors are sent to Login.
import { test, expect } from '@playwright/test';

const screens = [
  { path: 'Dashboard', title: 'HDB Resale Market Dashboard' },
  { path: 'Explore', title: 'Explore Resale Transactions' },
  { path: 'Towns', title: 'Compare Towns' },
  { path: 'Affordability', title: 'Affordability Calculator' },
];

for (const s of screens) {
  test(`${s.path} renders without client errors`, async ({ page }) => {
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(s.path);
    await expect(page.getByRole('heading', { name: s.title }).or(page.getByText(s.title, { exact: true })).first()).toBeVisible();
    expect(errors).toEqual([]);
  });
}

test('root opens the Dashboard (default screen)', async ({ page }) => {
  await page.goto('');
  await expect(page).toHaveURL(/\/HomeScope\/(Dashboard)?/);
  await expect(page.getByText('HDB Resale Market Dashboard').first()).toBeVisible();
});

test('top menu navigates between screens', async ({ page, isMobile }) => {
  test.skip(isMobile, 'menu collapses into a hamburger on mobile');
  await page.goto('Dashboard');
  for (const s of screens.slice(1)) {
    await page.getByRole('menuitem', { name: s.path, exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(`/${s.path}`));
  }
});

test('Admin is hidden from the menu and blocked for a standard user', async ({ page }) => {
  await page.goto('Dashboard');
  await expect(page.getByText('HDB Resale Market Dashboard').first()).toBeVisible();
  await expect(page.locator('a', { hasText: /^Admin$/ })).toHaveCount(0);
  await page.goto('Admin');
  await expect(page).toHaveURL(/InvalidPermissions|\/Login/);
});

test.describe('anonymous visitor', () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  for (const path of ['Dashboard', 'Admin']) {
    test(`${path} redirects to the Login screen`, async ({ page }) => {
      await page.goto(path);
      await expect(page).toHaveURL(/\/Login/);
      await expect(page.getByRole('button', { name: 'Login' })).toBeVisible();
    });
  }
});
