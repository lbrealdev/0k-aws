# Use case: payer-central dynamic budgets and billing alerts

Sanitized architecture notes for a **multi-account AWS Organization** where spend controls live in the **management (payer) account** and budget limits are **rewritten monthly by automation**.

This document uses **illustrative names and numbers only**. It does not describe a specific customer, account IDs, dollar amounts, or environments from any real engagement.

## Topology (illustrative)

```text
AWS Organization
|
+-- Management / payer account   (1)   <-- budgets + billing alerts live here
|
+-- Member / project accounts    (N)   <-- workloads; spend attributed via LinkedAccount
    (example: dozens of accounts under one or more OUs)
```

**Pattern rules for this use case**

- Budgets are defined in the **management account**, covering member accounts (all or most).
- Billing alerts observed for this pattern also live in the **management account** only (region **`us-east-1`** for billing metrics).
- Member accounts are not the home of these centralized budget/alert objects.

## Control plane: monthly dynamic budgets

Budgets are **not static year-round caps**. A scheduled job recalculates and updates them.

```text
EventBridge rule  (example: cron on day 5 of each month)
        |
        v
  Lambda (Python)  -->  create/update Budgets in management account
        |
        +--> DynamicBudget-Monthly-ForecastedBreaches   (WARN-style)
        +--> DynamicBudget-Monthly-Breached             (CRIT-style)
        |
        v
     SNS / downstream ticket tooling (optional)
```

| Example budget name | Typical intent | Severity label (org convention) |
|---------------------|----------------|----------------------------------|
| `DynamicBudget-Monthly-ForecastedBreaches` | Forecast will exceed the limit | WARN-style |
| `DynamicBudget-Monthly-Breached` | Actual spend crossed the limit | CRIT-style |

Exact notification types, SNS topics, and ticket wiring vary by implementation. The important idea: **limits move every month by design**.

### Why a “static threshold review” never closes

If you treat budget amounts or related alert thresholds as fixed misconfigurations, the review never finishes:

1. Month N: limits look “too low” or “too high” vs recent spend.
2. Day 5 (example): Lambda rewrites budgets for the new month.
3. Month N+1: the same comparison yields a different story.

So drift vs last month’s peak is expected unless you also understand the **Lambda formula** (inputs, headroom %, forecast vs actual, per-account rules).

## Billing alerts vs Budgets (two layers)

This use case often has **both**:

```text
Policy / limits          Runtime watchers              Human follow-up
-----------------        ------------------            ----------------
AWS Budgets       -->    Budget notifications   -->    SNS / Jira / email
(dynamic, monthly)       (Forecasted / Breached)

CloudWatch billing -->   Alarm state changes    -->    SNS / Jira / email
alarms (us-east-1)       (EstimatedCharges …)
```

Budgets are the **control plane** for agreed/computed caps. CloudWatch billing alarms (when present) are **additional watchers** on `EstimatedCharges` (MTD) in `us-east-1`, usually also centralized on the payer with a `LinkedAccount` (or equivalent) dimension.

### Open investigation: dynamic CloudWatch

In some deployments, CloudWatch billing alarm thresholds may also be updated over time (manually or by automation), which makes them look “wrong” against yesterday’s spend even when the system is behaving as designed.

**Status for this use case doc:** CloudWatch dynamism is an **open question** — confirm whether:

- alarms are static and only Budgets move, or
- a job (same or another Lambda) updates alarm thresholds too, or
- alarms were created once and now diverge from the monthly budget logic.

Until that is confirmed, do not assume CloudWatch CRIT/WARN values are permanent.

## WARN / CRIT policy (illustrative — not a decision record)

Orgs sometimes label forecast notifications as WARN-style and actual breach as CRIT-style, and later discuss retiring WARN-style signals.

For documentation and tooling: treat WARN-removal as a **possible future policy**, not as an approved client decision, until explicitly confirmed.

## Illustrative numbers (fake)

These figures are **examples only** to explain bands. They are not defaults and must not be copied into reports as if measured.

| Member account (fake) | Typical month spend (fake) | Example dynamic budget (fake) |
|-----------------------|----------------------------|-------------------------------|
| `111122223333` | ~$4,000 | Budget rewritten monthly near that range +/- headroom |
| `444455556666` | ~$25,000 | Same pattern, different scale |

Assessment tooling should always use **live** Budget amounts and metrics for the account under review, never these table values.

## Implications for analysis tooling

A useful read-only analyzer for this pattern should eventually:

1. Inventory **Budgets** in the management account (names, limits, filters, notification types).
2. Record **automation** (EventBridge rule schedule + Lambda that mutates budgets).
3. Inventory **CloudWatch** billing alarms in the management account (`us-east-1`).
4. Pair each signal to a **member account** (`LinkedAccount` / cost filter / name).
5. Compare alarm thresholds to **current** budget limits and recent spend — and flag when budgets are known-dynamic so “misconfigured” is not over-claimed.

The existing helper [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) focuses on CloudWatch inventory/assess plus Budget **read** as a secondary signal. It does not yet decode the monthly Lambda formula or prove whether CloudWatch thresholds are also automated.

## Related

- [Billing alarm misconfigurations](./billing-alarm-misconfigurations.md) — MTD / threshold misconceptions and verdict codes
- [`scripts/README.md`](./scripts/README.md) — CLI for the CloudWatch-oriented analyzer
- [auth/](../auth/README.md) — SSO profiles for the management account
