// Signs in once with a standard (non-admin) end-user account and saves the
// session for the other specs. Credentials come from E2E_USERNAME / E2E_PASSWORD
// (GitHub Actions secrets in CI); they are never stored in the repository.
import { test as setup, expect } from '@playwright/test';

const STATE = 'playwright/.auth/user.json';

setup('sign in as a standard user', async ({ page }) => {
  const { E2E_USERNAME: user, E2E_PASSWORD: pass } = process.env;
  if (!user || !pass) throw new Error('Set E2E_USERNAME and E2E_PASSWORD (a non-admin HomeScope end-user account).');
  await page.goto('Login');
  await page.getByPlaceholder('Username').or(page.locator('input[type="text"], input[type="email"]')).first().fill(user);
  await page.locator('input[type="password"]').fill(pass);
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page).not.toHaveURL(/\/Login/);
  await page.context().storageState({ path: STATE });
});
