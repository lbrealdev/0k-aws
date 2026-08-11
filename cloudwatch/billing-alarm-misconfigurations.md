# Billing alarm misconfigurations

Notes for CloudWatch `AWS/Billing` / `EstimatedCharges` alarms used as WARN/CRIT spend alerts — especially when alarms are **centralized** in a payer/shared account and represent many linked accounts.

Use with [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) (`inventory` then `assess`).

## How EstimatedCharges behaves

- `EstimatedCharges` is **month-to-date (MTD)** spend, not a daily spike detector.
- Values climb through the month and typically reset after month boundary.
- Once MTD crosses a fixed threshold, a `GreaterThanOrEqualToThreshold` alarm often stays in `ALARM` until reset.
- Billing metrics are published in **`us-east-1`** only.
- In a **payer/central** account, per-member spend needs the `LinkedAccount` dimension (or an equivalent identifier in the alarm name) to be assessable.

## WARN vs CRIT

Naming convention in this org (example):

`billing-…-estimatedcharges-WARN` / `billing-…-estimatedcharges-CRIT`

| Severity | Intent | Current policy |
|----------|--------|----------------|
| WARN | Early warning / softer threshold | **Approved for removal** — keep CRIT only |
| CRIT | Hard / overspend signal | Keep and **right-size** the threshold |

## Misconcepts (common failures)

1. **Treating MTD as a burst metric** — CloudWatch billing alarms do not detect short spikes the way EC2 CPU alarms do.
2. **CRIT ≈ normal monthly spend** — if the account usually ends the month near $10k, a CRIT at $10k alarms on a *normal* month, not overspend.
3. **Tiny reused thresholds** — CRIT at $10 or $1k on a ~$9–10k account fires early every month (`CRIT_TOO_LOW`).
4. **No account pairing** — centralized alarms without `LinkedAccount` (and without a 12-digit account id in the name) cannot be validated against that account’s spend.
5. **Ignoring Budgets** — AWS Budgets (actual/forecast %) often express the real agreed cap; CloudWatch CRIT should not drift far from that story.
6. **Member vs payer confusion** — member accounts only see their own charges; org-wide / linked-account views belong on the payer with `LinkedAccount`.

## Threshold guidance

For an account that typically spends about **$9k–$10k/month**:

| Setting | Example | Assessment |
|---------|---------|------------|
| CRIT $10 or $1k | Far below normal month | Too low — fires early (`CRIT_TOO_LOW`) |
| CRIT $10k | ≈ normal month total | At baseline — weak CRIT / month-end noise (`CRIT_AT_BASELINE`) |
| CRIT ~$11k–$12k | ≈ 110–120% of expected month (or budget×1.1–1.2) | Sensible overspend headroom (`CRIT_OK_HEADROOM`) |
| CRIT much higher | Rarely trips | Too high / weak protection (`CRIT_TOO_HIGH`) |

Primary spend signal used by the script: **previous calendar month maximum** `EstimatedCharges` for the linked account. Secondary: matching **AWS Budget** limit on the central account.

## Finding / verdict codes

### Inventory (`inventory`)

| Code | Severity | Meaning |
|------|----------|---------|
| `WARN_REMOVE_CANDIDATE` | info | WARN alarm — removal candidate |
| `MISSING_LINKED_ACCOUNT` | error | No `LinkedAccount` dimension and no account id in name |
| `UNMAPPED_ACCOUNT` | error | Cannot pair alarm → account |
| `LINKED_ACCOUNT_FROM_NAME` | info | Account id inferred from alarm name |
| `UNEXPECTED_SHAPE` | warn | Not EstimatedCharges + Maximum + >= threshold |
| `MISSING_CURRENCY` | warn | No `Currency` dimension |
| `WRONG_REGION` | error | Scan region is not `us-east-1` |

### Assess (`assess`)

| Verdict | Meaning |
|---------|---------|
| `CRIT_TOO_LOW` | Threshold ≤ 50% of last-month peak (or ≪ budget) |
| `CRIT_AT_BASELINE` | Threshold within ~0–10% of last-month peak |
| `CRIT_OK_HEADROOM` | Threshold ~10–30% above peak (or ~budget×1.1–1.2) |
| `CRIT_TOO_HIGH` | Threshold > 30% above peak and not justified |
| `CRIT_VS_BUDGET_DRIFT` | CRIT and Budget limit differ by > 25% |
| `NO_SPEND_SIGNAL` | No metric datapoints and no matching Budget |
| `UNMAPPED_ACCOUNT` | CRIT row has no linked account |

## Related

- [`scripts/README.md`](./scripts/README.md) — CLI for `inventory` / `assess`
- [auth/](../auth/README.md) — SSO profiles for the central account
