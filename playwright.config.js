import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.HOMESCOPE_URL ?? 'https://personal-ljonxgvs.outsystemscloud.com/HomeScope/';

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 60_000,
  expect: { timeout: 20_000 },
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }], ...(process.env.CI ? [['github']] : [])],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    // Local runs reuse the installed Chrome; CI installs Playwright's Chromium.
    channel: process.env.CI ? undefined : 'chrome',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    { name: 'mobile', use: { ...devices['Pixel 7'] }, testMatch: /smoke\.spec\.js/ },
  ],
});
