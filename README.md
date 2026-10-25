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
- **Explore.** Search, filter, sort and page through individual transactions. Filtering, sorting and paging run on the server.
- **Towns.** Compares all 26 HDB towns with a chart and a sortable stats table.
- **Affordability.** A loan instalment calculator (annuity formula) with a check against the 30% Mortgage Servicing Ratio.
- **Admin** (registered users only). Starts a sync or full refresh and shows the sync run history.

## Architecture (summary)

The modules follow the OutSystems Architecture Canvas. Full detail is in [docs/architecture.md](docs/architecture.md).

| Layer | Module | Application | Responsibility |
|---|---|---|---|
| End-user | `HomeScope` (Reactive) | HomeScope | Screens, UX, client-side state |
| Core | `Resale_CS` | HomeScope Services | Entities, incremental sync (timer), analytics and affordability logic |
| Foundation | `DataGov_IS` | HomeScope Services | data.gov.sg REST integration, typed structures, retries, error translation |

**How the data gets in:**

1. `SyncResaleTimer` runs daily at 02:00, or when an admin clicks *Sync now*. It pages data.gov.sg 5,000 rows at a time.
2. Each page is upserted with **one set-based SQL statement** (OPENJSON → MERGE) and committed straight away.
3. Each run handles at most 10 pages, then re-wakes its own timer until the dataset is complete.
4. The load is idempotent, keyed on the source `_id`. Every run is recorded in `SyncRun`.

## Repository layout

```
.github/workflows/   ci.yml (validate + tests), deploy.yml (Terraform + LifeTime promotion)
docs/                architecture.md
infra/terraform/     root module, modules/{network,database,platform,observability}, envs/, bootstrap/
scripts/             lifetime-deploy.mjs (LifeTime Deployment API v2)
tests/contract/      data.gov.sg API contract tests (node:test)
tests/e2e/           Playwright UI tests (smoke, affordability, data exploration)
outsystems/          exported .oml modules
```

## Running the tests

You need Node 20 or later.

```bash
npm ci
npx playwright install chromium

npm run test:contract                     # data.gov.sg contract: envelope, schema, formats, paging, filters
HOMESCOPE_EXPECT_DATA=0 npx playwright test   # UI smoke + affordability (works on an empty environment)
npx playwright test                       # full suite incl. data exploration (needs a completed sync)
HOMESCOPE_URL=https://<host>/HomeScope/ npx playwright test   # point at another environment
```

| Suite | What it proves |
|---|---|
| `contract/datagov.contract.test.js` | The upstream API still matches the shape that `DataGov_IS` and the OPENJSON upsert depend on. It checks field names, string-encoded numbers, month and storey formats, contiguous `_id` paging and JSON filters. It runs daily in CI to catch drift before it breaks the sync. |
| `e2e/smoke.spec.js` | Every screen renders without client errors, the menu navigation works, and Admin requires sign-in. |
| `e2e/affordability.spec.js` | The instalment calculation, the MSR within/exceeds messages and the 0% interest edge case. |
| `e2e/data.spec.js` | KPIs and charts populate, filters narrow the results, and Explore search, sort and pagination work. Towns lists every town. |

You can set `DATAGOV_API_KEY` to use the authenticated data.gov.sg tier. The contract tests pace their calls and back off on HTTP 429 when running anonymously.

**Last verified run (25 Oct 2026, Dev):** the initial sync loaded 243,500 / 243,500 records in 5 chained timer runs (about 8 minutes, no errors). Contract tests passed 5/5 and Playwright desktop passed 14/14.

## Infrastructure (Terraform on AWS)

The Terraform provisions a **self-managed OutSystems 11 environment**, one per stage (dev and prod):

- a 3-tier VPC across 2–3 AZs;
- an ALB with WAFv2 in front;
- an auto-scaling group of Windows front-ends plus a deployment controller;
- RDS SQL Server, encrypted, with Multi-AZ in prod;
- Secrets Manager for credentials, VPC endpoints, CloudWatch logs, alarms and a dashboard, an SNS topic for alerts, and AWS Backup.

The servers bootstrap themselves with an idempotent PowerShell script that installs the Platform Server and runs `ConfigurationTool`.

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
| `ci.yml` | PR, push to `main`, daily, manual | `terraform fmt/validate`, tflint, checkov · contract tests · Playwright e2e against Dev (HTML report uploaded) |
| `deploy.yml` | manual (`dev` / `prod`) | Terraform plan and optional apply through AWS OIDC · LifeTime API: tag a version and promote **HomeScope Services → HomeScope** from Development to Production · smoke tests on Prod |

The workflows need these secrets and variables:

- **Secrets:** `AWS_DEPLOY_ROLE_ARN`, `AWS_ACCOUNT_ID`, `LIFETIME_URL`, `LIFETIME_TOKEN` (a LifeTime service account), and optionally `DATAGOV_API_KEY`.
- **Variables:** `HOMESCOPE_URL` and `HOMESCOPE_PROD_URL`.

The `prod` GitHub environment needs a required reviewer.

## Environment access

- **App:** https://personal-ljonxgvs.outsystemscloud.com/HomeScope/. The public screens need no login.
- **Admin screen:** a reviewer account is provided separately; credentials are never committed.
- **Service Studio / Service Center:** the OutSystems personal environment `personal-ljonxgvs`. Access can be shared on request.

## Assumptions and trade-offs

- The live demo runs on an OutSystems **Personal Environment** (OutSystems Cloud), because self-managed installers need a commercial license. The Terraform targets the self-managed AWS topology, which is what you would use in production.
- The sync uses the row count as its resume offset. This works because the source resource is append-only in `_id` order. *Full refresh* reconciles any changes upstream.
- Analytics are computed in SQL on indexed columns (town, flat type, month). Each screen requests only aggregates or one page of rows.
