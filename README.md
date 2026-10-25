# HomeScope SG

HomeScope SG is a full-stack **OutSystems 11** web app for exploring Singapore HDB resale prices. It uses the
data.gov.sg dataset *Resale flat prices based on registration date from Jan-2017 onwards*, which has about 243k
transactions.

This repository contains the delivery assets around the OutSystems modules:

- **Terraform IaC** that deploys and operates OutSystems on AWS;
- **automated tests**;
- **CI/CD** workflows;
- **architecture documentation**.

| | |
|---|---|
| **Live app (Dev)** | https://personal-ljonxgvs.outsystemscloud.com/HomeScope/ |
| **Architecture** | [docs/architecture.md](docs/architecture.md) |
| **IaC** | [infra/terraform](infra/terraform) |
| **Tests** | [tests/](tests) |

## Features

- **Dashboard.** Market KPIs (transactions, median and average price, price per sqm), a monthly price trend and volume by flat type. All of them filter by town, flat type and period.
- **Explore.** Search (street, block or flat model, 3+ characters), filter, sort and page through individual transactions. Filtering, sorting and paging run on the server.
- **Towns.** Compares all 26 HDB towns with a chart and a sortable stats table.
- **Fair Price Check (decision support).** Enter a flat and its asking price. A weighted k-nearest-neighbour model values it from the 30 most similar time-adjusted sales, then returns a verdict (below, fair, above market, or overpriced), a fair range, an opening offer, a walk-away price, the cash over valuation and the 6-month momentum. It also lists the sales behind the estimate and its back-tested accuracy against a naive town and flat-type median (see [architecture §4a](docs/architecture.md#4a-decision-support-fair-price-check-bi--ml)). This is where the app moves from *explore* to *decide*.
- **Affordability.** A loan instalment calculator (annuity formula) with a check against the 30% Mortgage Servicing Ratio.
- **Admin** (`HomeScopeAdmin` role only, checked on the screen, in the menu and in every server action). Starts a sync or, after a confirmation, a full refresh, and shows the sync run history.
- **Rules API.** `Resale_CS` exposes the verdict, affordability and sync self-test rules over REST (`/Resale_CS/rest/RulesAPI/`), so CI tests the same server actions the screens use.

## Architecture (summary)

The modules follow the OutSystems Architecture Canvas. Full detail is in [docs/architecture.md](docs/architecture.md).

![Architecture Canvas](docs/architecture-canvas.png)

| Layer | Module | Application | Responsibility |
|---|---|---|---|
| End-user | `HomeScope` (Reactive) | HomeScope | Screens, UX, client-side state |
| Core | `Resale_CS` | HomeScope Services | Entities, incremental sync (timer), analytics, affordability, fair-value model and its nightly back-test |
| Foundation | `DataGov_IS` | HomeScope Services | data.gov.sg REST integration, typed structures, retries, error translation |

**How the data gets in:**

1. `SyncResaleTimer` runs daily at 02:00, or when an admin clicks *Sync now*. It pages data.gov.sg 5,000 rows at a time. HTTP 429 and 5xx responses are retried with backoff (2 / 4 / 8 / 15 s).
2. Each page is upserted with **one set-based SQL statement** (OPENJSON → UPDATE only the rows that changed, detected with `INTERSECT` → INSERT new rows) and committed straight away.
3. Each run handles at most 10 pages, then re-wakes its own timer until the dataset is complete.
4. The load is idempotent, keyed on the source `_id`. Every run is recorded in `SyncRun`.
5. *Full refresh* re-reads everything and stamps each row it sees (`LastSeenOn`). It then deletes rows the source no longer has, but only if at least 98% of the source was read.

## Repository layout

```
.github/workflows/   ci.yml (validate + tests), deploy.yml (Terraform + LifeTime promotion)
docs/                architecture.md, architecture-canvas.svg/.png
infra/terraform/     root module, modules/{network,database,platform,observability}, envs/, bootstrap/
scripts/             lifetime-deploy.mjs (LifeTime Deployment API v2)
tests/unit/          lifetime-deploy.mjs unit tests (node:test, mocked LifeTime API)
tests/rules/         business-rule tests against the Resale_CS Rules API (node:test)
tests/contract/      data.gov.sg API contract tests (node:test)
infra/terraform/tests/  terraform test: prod guardrails, platform and LifeTime plans
tests/e2e/           Playwright UI tests (smoke, affordability, fair price, data exploration)
outsystems/          exported .oml modules
```

## Running the tests

You need Node 20 or later.

```bash
npm ci
npx playwright install chromium

npm run test:unit                         # LifeTime deploy script (no network)
npm run test:rules                        # verdict, confidence, negotiation, affordability, sync self-test
npm run test:contract                     # data.gov.sg contract: envelope, schema, formats, paging, filters
HOMESCOPE_EXPECT_DATA=0 npx playwright test   # UI smoke + affordability (works on an empty environment)
npx playwright test                       # full suite incl. data exploration (needs a completed sync)
HOMESCOPE_URL=https://<host>/HomeScope/ npx playwright test   # point at another environment
```

| Suite | What it proves |
|---|---|
| `unit/lifetime-deploy.test.js` | The deploy script tags and promotes Services before the UI, promotes to Production only the version running unmodified in Test, treats warnings, errors and aborts as failures, and validates its configuration before any call. |
| `rules/rules-api.test.js` | The business rules on the live server: verdict thresholds at the −5 / 5 / 10% boundaries, NODATA under 5 comparables, the confidence matrix, opening offer / walk-away / COV, the annuity and MSR maths (including 0% interest), and input validation. It also checks that the sync upsert is idempotent and detects changes. That check runs in a rolled-back transaction and is disabled in prod by `EnableSelfTest`. |
| `contract/datagov.contract.test.js` | The upstream API still matches the shape that `DataGov_IS` and the OPENJSON upsert depend on. It checks field names, string-encoded numbers, month and storey formats, contiguous `_id` paging and JSON filters. It runs daily in CI to catch drift before it breaks the sync. |
| `e2e/smoke.spec.js` | Every screen renders without client errors, the menu navigation works, the Admin link is hidden from anonymous users and the Admin screen requires sign-in. |
| `e2e/affordability.spec.js` | The instalment calculation, the MSR within/exceeds messages and the 0% interest edge case. |
| `e2e/fairprice.spec.js` | The verdict and negotiation plan rules (offer ≤ fair value, walk-away ≤ asking, COV = asking − valuation), 10 comparables that fit without scrolling, and a low asking price that flips the verdict to *Below market value* with zero COV. |
| `e2e/data.spec.js` | KPIs and charts populate, filters narrow the results, and Explore search, sort and pagination work. Towns lists every town. |

You can set `DATAGOV_API_KEY` to use the authenticated data.gov.sg tier. The contract tests pace their calls and back off on HTTP 429 when running anonymously.

**Last verified run (25 Oct 2026, Dev):** the initial sync loaded 243,500 / 243,500 records in 5 chained timer runs (about 8 minutes, no errors). Unit 8/8, rules 8/8, contract 5/5, and Playwright (desktop and mobile) 22 passed, 1 skipped. The skipped test is a desktop-only menu check.

## Infrastructure (Terraform on AWS)

The Terraform provisions **self-managed OutSystems 11 environments**: `lifetime` (the LifeTime console, controller only, private), `dev`, `test` and `prod`. Each stage gets:

- a 3-tier VPC across 2–3 AZs;
- an ALB with WAFv2 in front;
- an auto-scaling group of Windows front-ends plus a deployment controller;
- RDS SQL Server, encrypted, with Multi-AZ in prod;
- Secrets Manager for credentials, VPC endpoints, CloudWatch logs, alarms and a dashboard, an SNS topic for alerts, and AWS Backup.

The servers bootstrap themselves with an idempotent PowerShell script that installs the Platform Server and runs `ConfigurationTool`.

> **Status:** the IaC is validated (`terraform fmt`, `validate`, tflint, checkov with hard fail, and plan-only `terraform test` with a mocked provider) but has **not been applied** to an AWS account, since that needs a commercial OutSystems license. The guardrails in `main.tf` reject a prod plan without Multi-AZ, deletion protection or HTTPS.

```bash
cd infra/terraform

# 1. One-off per AWS account: state bucket, lock table, GitHub OIDC deploy role
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var github_repo=<owner>/<repo>

# 2. Upload installers to the artifacts bucket (output: artifacts_bucket)
#    installers/PlatformServer-11.latest.exe   (licensed OutSystems Platform Server)
#    installers/dotnet-hosting-8.0-win.exe     (keys configurable: platform_installer_key, dotnet_hosting_installer_key)

# 3. Deploy an environment (replace <account-id> in envs/<env>.backend.hcl)
terraform init -backend-config=envs/dev.backend.hcl
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

After `apply`:

1. Install the OutSystems license in Service Center at `https://<controller>/ServiceCenter`. It is reachable only through SSM port forwarding, because the ALB blocks it.
2. Register the environment in LifeTime.
3. Deploy the applications **HomeScope Services** and then **HomeScope**.

Important outputs: `app_url`, `alb_dns_name`, `db_endpoint`, `controller_instance_id`, `alerts_topic_arn`.

**Operations:**

- Connect to servers with `aws ssm start-session --target <id>`. No RDP or SSH ports are open.
- Front-ends scale on CPU. A new instance takes traffic only once `/HomeScope/` responds, which is enforced by the lifecycle hook.
- Database passwords are in Secrets Manager (`<name>/outsystems/platform`). The RDS master password is managed by RDS.
- Alarms go to SNS: ALB 5xx, p95 latency, unhealthy hosts, RDS CPU and storage, and controller status checks. Set `alert_emails` to subscribe.

## CI/CD

| Workflow | Trigger | Steps |
|---|---|---|
| `ci.yml` | PR, push to `main`, daily, manual | `terraform fmt/validate/test`, tflint, checkov (hard fail, reviewed skips in `.checkov.yaml`) · unit · rules API · contract · Playwright e2e against Dev (HTML report uploaded) |
| `deploy.yml` | manual (`lifetime` / `dev` / `test` / `prod`) | **plan** with a read-only OIDC role, plan shown in the run summary → **apply** that exact plan after a reviewer approves (test, prod, lifetime) → **promote** through LifeTime: Development → Test tags the version, Test → Production deploys only the version running unmodified in Test, **HomeScope Services** before **HomeScope** → record the release in SSM (`/homescope-<env>/release`) so new front-ends wait for it → **smoke** tests on the target |

The workflows need these secrets and variables:

- **Secrets:** `AWS_DEPLOY_ROLE_ARN`, `AWS_ACCOUNT_ID`, `LIFETIME_URL`, `LIFETIME_TOKEN` (a LifeTime service account), and optionally `DATAGOV_API_KEY`.
- **Variables:** `HOMESCOPE_URL`, `HOMESCOPE_TEST_URL` and `HOMESCOPE_PROD_URL`.

The `test`, `prod` and `lifetime` GitHub environments need required reviewers. The `<env>-plan` environments need none.

## Environment access

- **App:** https://personal-ljonxgvs.outsystemscloud.com/HomeScope/. The public screens need no login.
- **Admin screen:** a reviewer account is provided separately; credentials are never committed. The account needs the `HomeScopeAdmin` role, granted in the Users app.
- **Service Studio / Service Center:** the OutSystems personal environment `personal-ljonxgvs`. Access can be shared on request.

## Decisions and non-functional requirements

**Platform: OutSystems Cloud vs self-managed OutSystems 11 on AWS vs ODC**

| Option | For | Against | Decision |
|---|---|---|---|
| OutSystems Cloud (PaaS) | Managed infra, patching, LifeTime included | Licensed per environment; no IaC to show | Used for the live demo (Personal Environment) |
| Self-managed O11 on AWS | Full control of network, data residency, cost and scaling; fits a bank's landing zone | We run patching, DR and capacity | **Target production topology** (this Terraform) |
| ODC | Cloud-native, containers, no farms to run | Different architecture (no Architecture Canvas modules or LifeTime API v2); the brief asks for O11 | Not chosen |

**Non-functional requirements (targets)**

| NFR | Target | How it is met |
|---|---|---|
| Availability | 99.9% (prod) | 3 AZs, 2–6 front-ends behind the ALB, Multi-AZ RDS, auto-recovering controller |
| Performance | Screens p95 < 2 s | Aggregates on indexed columns, one page of rows per request, p95 latency alarm |
| Data freshness | ≤ 24 h behind data.gov.sg | Daily sync, backoff on 429, failed runs visible in Admin and alerted |
| Recovery | RPO 24 h / RTO 4 h (single region) | RDS automated backups + AWS Backup; the data can be fully re-synced from source |
| Security | No public admin surface; least access | WAF, ALB blocks consoles, SSM only, Secrets Manager, KMS, `HomeScopeAdmin` role |

## Assumptions and trade-offs

- The live demo runs on an OutSystems **Personal Environment** (OutSystems Cloud), because self-managed installers need a commercial license. The Terraform targets the self-managed AWS topology, which is what you would use in production.
- **Sync.** The resume offset is the row count, which works because the source resource is append-only in `_id` order. Retro edits upstream are picked up by *Full refresh* (change-detecting upsert plus a guarded mark-and-sweep), not by the daily run.
- Analytics are computed in SQL on indexed columns (town, flat type, month). Each screen requests only aggregates or one page of rows.
- **Caching.** Analytics actions are set to Server Side Caching (60 min), but caching is not licensed on the Personal Environment, so it has no effect there.
- **Admin link.** The menu hides the Admin link through a data action that calls `CheckHomeScopeAdminRole`. This is cosmetic: the screen role and the server-side check in every admin action are what enforce access.
- **Rules API placement.** The REST API lives in `Resale_CS` to keep the module count small. A larger estate would expose it from a separate `_API` module.
- **Not built, on purpose (would be next):**
  - a `Valuation_BL` module split out of `Resale_CS`, a custom `_Th` theme and reusable KpiCard block, and a Verdict static entity;
  - a golden AMI built with Packer, and ASG termination hooks to drain front-ends;
  - tighter IAM least privilege on the deploy role, and multi-region DR;
  - an `hsconf` schema check, and separate RabbitMQ credentials per environment.
- **Not verified live** (no self-managed farm or LifeTime available):
  - the OSPTool publish step and `/SetPlatformServerAdminPassword` in the bootstrap;
  - the LifeTime API version-check fields used by `lifetime-deploy.mjs`, which are covered by mocked unit tests only.
- **Manual steps.** Dev's `/homescope-dev/release` parameter is set by hand, because Dev is not a promotion target. Secret rotation is a runbook item (checkov `CKV2_AWS_57`), because the Configuration Tool applies the platform passwords.
