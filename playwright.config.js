import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.HOMESCOPE_URL ?? 'https://personal-ljonxgvs.outsystemscloud.com/HomeScope/';
const AUTH = 'playwright/.auth/user.json'; // written by tests/e2e/auth.setup.js

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 60_000,
  expect: { timeout: 20_000 },
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }], ...(process.env.CI ? [['github']] : [])],
  use: {
    baseURL,
    // No traces in CI: they would put the signed-in session into the public artifact.
    trace: process.env.CI ? 'off' : 'retain-on-failure',
    screenshot: 'only-on-failure',
    // Local runs reuse the installed Chrome; CI installs Playwright's Chromium.
    channel: process.env.CI ? undefined : 'chrome',
  },
  projects: [
    // Screens require sign-in: log in once, reuse the session in every project.
    { name: 'setup', testMatch: /auth\.setup\.js/ },
    { name: 'desktop', dependencies: ['setup'], use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 }, storageState: AUTH } },
    { name: 'mobile', dependencies: ['setup'], use: { ...devices['Pixel 7'], storageState: AUTH }, testMatch: /smoke\.spec\.js/ },
  ],
});
