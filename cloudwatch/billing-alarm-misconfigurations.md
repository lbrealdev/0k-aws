# Billing alarm misconfigurations

Notes for CloudWatch `AWS/Billing` / `EstimatedCharges` alarms used as WARN/CRIT spend alerts - especially when alarms are **centralized** in a payer/shared account and represent many linked accounts.

Use with [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) (`inventory` then `assess`).

The script reports **live AWS data only** (alarm thresholds, last-month `EstimatedCharges`, Budgets). It does **not** inject example dollar amounts into inventory or assessment output.

## How EstimatedCharges behaves

- `EstimatedCharges` is **month-to-date (MTD)** spend, not a daily spike detector.
- Values climb through the month and typically reset after month boundary.
- Once MTD crosses a fixed threshold, a `GreaterThanOrEqualToThreshold` alarm often stays in `ALARM` until reset.
- Billing metrics are published in **`us-east-1`** only.
- In a **payer/central** account, per-member spend needs the `LinkedAccount` dimension (or an equivalent identifier in the alarm name) to be assessable.

## WARN vs CRIT

Naming convention in this org (example pattern only):

`billing-…-estimatedcharges-WARN` / `billing-…-estimatedcharges-CRIT`

| Severity | Intent | Current policy |
|----------|--------|----------------|
| WARN | Early warning / softer threshold | Sometimes proposed for removal; treat as **unconfirmed** until the org decides |
| CRIT | Hard / overspend signal | Usually keep and **right-size** (or align with dynamic Budgets) |

## Misconcepts (common failures)

1. **Treating MTD as a burst metric** - CloudWatch billing alarms do not detect short spikes the way EC2 CPU alarms do.
2. **CRIT ~= normal monthly spend** - if the threshold is set at a typical month-end total, the alarm fires on a *normal* month, not overspend.
3. **Tiny reused thresholds** - a CRIT far below real monthly spend fires early every month (`CRIT_TOO_LOW`).
4. **No account pairing** - centralized alarms without `LinkedAccount` (and without a 12-digit account id in the name) cannot be validated against that account's spend.
5. **Ignoring Budgets** - AWS Budgets (actual/forecast %) often express the real agreed cap; CloudWatch thresholds should not drift far from that story.
6. **Member vs payer confusion** - member accounts only see their own charges; org-wide / linked-account views belong on the payer with `LinkedAccount`.

## Threshold guidance (illustrative only)

The dollar figures below are **examples to explain the bands**, not defaults used by the script. Real assessments use each account's last-month peak and/or Budget limit.

| Pattern | Meaning | Assessment |
|---------|---------|------------|
| Threshold much lower than typical monthly spend | Fires early most months | `CRIT_TOO_LOW` |
| Threshold near typical month-end total | Alarms on a normal month | `CRIT_AT_BASELINE` |
| Threshold ~10-30% above typical spend (or ~budget x 1.1-1.2) | Overspend headroom | `CRIT_OK_HEADROOM` |
| Threshold far above typical spend / budget | Rarely trips | `CRIT_TOO_HIGH` |

Primary spend signal used by the script: **previous calendar month maximum** `EstimatedCharges` for the linked account. Secondary: matching **AWS Budget** limit on the central account. Per-row `suggested_crit` = `max(last_month_peak, budget_limit) * 1.1` when those signals exist.

## Finding / verdict codes

### Inventory (`inventory`)

| Code | Severity | Meaning |
|------|----------|---------|
| `WARN_REMOVE_CANDIDATE` | info | WARN-labelled alarm (policy may mark for removal later; not an approved decision by itself) |
| `MISSING_LINKED_ACCOUNT` | error | No `LinkedAccount` dimension and no account id in name |
| `UNMAPPED_ACCOUNT` | error | Cannot pair alarm to account |
| `LINKED_ACCOUNT_FROM_NAME` | info | Account id inferred from alarm name |
| `UNEXPECTED_SHAPE` | warn | Not EstimatedCharges + Maximum + >= threshold |
| `MISSING_CURRENCY` | warn | No `Currency` dimension |
| `WRONG_REGION` | error | Scan region is not `us-east-1` |

### Assess (`assess`)

Assesses **all** inventory alarms (WARN, CRIT, UNKNOWN).

| Verdict | Meaning |
|---------|---------|
| `CRIT_TOO_LOW` | Threshold <= 50% of last-month peak (or much below budget) |
| `CRIT_AT_BASELINE` | Threshold within ~0-10% of last-month peak |
| `CRIT_OK_HEADROOM` | Threshold ~10-30% above peak (or ~budget x 1.1-1.2) |
| `CRIT_TOO_HIGH` | Threshold > 30% above peak and not justified |
| `CRIT_VS_BUDGET_DRIFT` | Threshold and Budget limit differ by > 25% |
| `NO_SPEND_SIGNAL` | No metric datapoints and no matching Budget |
| `UNMAPPED_ACCOUNT` | Alarm row has no linked account |

WARN rows also note `WARN_REMOVE_CANDIDATE`. UNKNOWN severity is called out when the name has no WARN/CRIT token.

## Related

- [`scripts/README.md`](./scripts/README.md) - CLI for `inventory` / `assess`
- [auth/](../auth/README.md) - SSO profiles for the central account
