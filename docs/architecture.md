# HomeScope SG — Architecture

## 1. Architecture Canvas (3 layers)

```
┌──────────────────────────── End-user ────────────────────────────┐
│  HomeScope  (Reactive Web app "HomeScope")                       │
│  Screens: Dashboard · Explore · Towns · Affordability · Admin    │
└───────────────────────────────┬──────────────────────────────────┘
                                │ public read-only entities, server actions
┌──────────────────────────── Core ────────────────────────────────┐
│  Resale_CS   (app "HomeScope Services")                          │
│  Entities: ResaleTransaction, Town, FlatType, SyncRun, SyncStatus│
│  Logic: SyncResale + SyncResaleTimer, TriggerSync,               │
│         RequestFullRefresh, GetMarketKpis, GetPriceTrend,        │
│         GetTownStats, CalculateAffordability                     │
└───────────────────────────────┬──────────────────────────────────┘
                                │ GetResalePage(Offset, Limit)
┌──────────────────────────── Foundation ──────────────────────────┐
│  DataGov_IS  (app "HomeScope Services")                          │
│  Consumed REST API: data.gov.sg datastore_search                 │
│  Structures: DatastoreResponse/Result, ResaleRecord              │
│  Site props: DataGovApiKey, ResaleResourceId, MaxRetries         │
│  Exception: DataGovApiException                                  │
└──────────────────────────────────────────────────────────────────┘
```

Rules applied:

- No upward or sideways references. HomeScope → Resale_CS → DataGov_IS.
- The integration service (`_IS`) holds only the API contract, its typed structures and error translation. It has no persistence, so a different source or API version only changes this module.
- The core service (`_CS`) owns the business entities. It exposes them **read-only** (`ExposeReadOnly = true`), so all writes go through its own logic.
- The two services ship together as the application **HomeScope Services**. The UI ships as the application **HomeScope**, so the UI can be redeployed on its own.

## 2. Data model (Resale_CS)

| Entity | Purpose | Key / indexes |
|---|---|---|
| `ResaleTransaction` | One typed resale transaction (month, town, flat type, block, street, storey range, min/max storey, floor area, model, lease start, remaining lease in months, price, price per sqm) | `UX_ResaleTx_SourceRecordId` (unique, idempotent upsert key = data.gov.sg `_id`); `IX_ResaleTx_Town_FlatType_Month`; `IX_ResaleTx_Month` |
| `Town` / `FlatType` | Normalised reference data, created automatically during sync | unique `Name` |
| `SyncRun` | Audit row per sync: trigger, offsets, pages, fetched/inserted/updated, source total, error | – |
| `SyncStatus` (static) | Running · Succeeded · Failed | – |

Price per sqm and min/max storey are computed during ingestion, so analytics queries never parse strings.

## 3. Ingestion / sync design

```
SyncResaleTimer (daily 02:00, or woken by Admin › Sync now)
  └─ SyncResale
       create SyncRun(Running)
       Offset = COUNT(ResaleTransaction)            -- incremental resume point
       loop while HasMore and Page < Site.MaxPagesPerRun (10)
         DataGov_IS.GetResalePage(Offset, Site.SyncPageSize = 5000)
           (retries up to MaxRetries; raises DataGovApiException)
         UpsertPage: ONE set-based SQL statement
           OPENJSON(page) → typed CTE → MERGE Town / FlatType → MERGE ResaleTransaction
         CommitTransaction                           -- each page is durable
         Offset += page size; HasMore = Offset < Total
       SyncRun = Succeeded
       if HasMore → WakeSyncResaleTimer               -- chain the next batch
  on exception → SyncRun = Failed (+ message), logged, not rethrown
```

Design choices:

- **Bounded runs.** Each run handles at most 50,000 rows and then re-wakes its own timer. Runs stay far inside the timer timeout, and the ~243k-row initial load needs about five chained runs.
- **Idempotent.** The upsert is keyed on `SourceRecordId`. Re-running a page, or overlapping runs, cannot create duplicates.
- **Set-based.** Each page is one SQL round trip, not 5,000 aggregate calls. A page of 5,000 rows loads in seconds.
- **Commit per page.** If a run fails midway, the pages already loaded are kept, and the next run resumes from the current row count.
- **Observable.** The SyncRun history appears on the Admin screen.
- **Full refresh.** Admin › Full refresh calls `RequestFullRefresh`, which truncates the data and wakes the timer.
- **Trade-off.** Using the row count as the resume offset assumes the dataset is append-only in `_id` order, which holds for this data.gov.sg resource. A periodic full refresh corrects any retro edits upstream.

## 4. Frontend design (HomeScope)

| Screen | Purpose | Main elements |
|---|---|---|
| Dashboard (default) | Market at a glance | Filters (town, flat type, period); KPI cards (transactions, median/avg price, price per sqm); price trend line chart; volume by flat type bar chart |
| Explore | Transaction-level exploration | Search (street/block), town, flat type, price range; server-side sort (`OnSort` → dynamic ORDER BY) and pagination (20/page) |
| Towns | Compare towns | Bar chart of median price by town; sortable stats table; flat-type filter |
| Affordability | "Can I afford it?" | Price, down payment, interest, tenure, income → monthly instalment (annuity formula), MSR check against 30% |
| Admin (RegisteredRole) | Operations | Sync now, Full refresh, SyncRun history, record counts |

UX choices:

- Each screen fetches data through **server aggregates and data actions**, so only the current page or the aggregates reach the browser, never the 243k rows.
- Filters refresh their data sources on change. Empty states are shown before the first sync.
- The screens use the OutSystems UI responsive layout, with a hamburger menu on mobile.

## 5. Infrastructure (AWS, self-managed OutSystems 11)

```
                Internet
                   │  (WAFv2: rate limit, IP reputation, OWASP common, SQLi)
            ┌──────▼──────┐  public subnets (2–3 AZ)
            │     ALB      │  TLS 1.3, HTTP→HTTPS, blocks /ServiceCenter /LifeTime /ServiceStudio
            └──────┬──────┘
   app subnets     │ :80
   ┌───────────────▼───────────────┐      ┌─────────────────────┐
   │ Front-end ASG (Windows 2022,  │◄────►│ Deployment Controller│  (EC2, auto-recover,
   │ IIS + OutSystems Platform     │ 12000│ + Service Center     │   AWS Backup daily)
   │ Server; lifecycle-hook ready) │ 5672 │ controller.<env>.internal (private zone)
   └───────────────┬───────────────┘      └──────────┬──────────┘
   data subnets    │ 1433 (TLS forced)               │
            ┌──────▼─────────────────────────────────▼─┐
            │ RDS SQL Server SE (KMS, Multi-AZ in prod,│
            │ Secrets Manager master password, PI, EM) │
            └──────────────────────────────────────────┘
 VPC endpoints: S3 (gateway), SSM, SSM Messages, EC2 Messages, Secrets Manager, Logs, Monitoring
 S3: artifacts (installers, server.hsconf template), logs (ALB, VPC flow logs)
 CloudWatch: IIS / platform / Windows logs, alarms → SNS, ops dashboard
```

- **Bootstrap.** Each server runs `bootstrap.ps1` from user data. The script is idempotent:
  1. Formats the D: data disk.
  2. Installs IIS and .NET.
  3. Installs the Platform Server.
  4. Renders `server.hsconf` and runs `ConfigurationTool.com /SetupInstall`.
  5. On the controller only, installs Service Center.
  6. Starts the CloudWatch agent.
- **Front-end readiness.** A new front-end joins the target group only after `/HomeScope/` answers, through the ASG lifecycle hook. Rolling instance refresh gives zero-downtime AMI and config updates.
- **No inbound admin ports.** Admin access is through SSM Session Manager only. Database passwords are generated by Terraform and kept in Secrets Manager.
- **Environments.** `envs/dev.tfvars` is cost-optimised: 2 AZs, a single NAT and one front-end. `envs/prod.tfvars` is highly available: 3 AZs, a NAT per AZ, Multi-AZ RDS, 2–6 front-ends and deletion protection.

## 6. Delivery pipeline

```
PR / push ──► CI: terraform fmt+validate+tflint+checkov │ contract tests (data.gov.sg) │ Playwright e2e (Dev)
manual    ──► Deploy: terraform plan/apply (OIDC role) ─► LifeTime API: tag + deploy Dev→Prod ─► smoke tests on Prod
daily     ──► CI contract tests: detect upstream data.gov.sg schema drift
```
