# CloudWatch

Operational guides and read-only helpers for Amazon CloudWatch — especially **payer-central** billing alarms and how they relate to dynamic AWS Budgets.

## Guides

- [Billing alarm misconfigurations](./billing-alarm-misconfigurations.md) — MTD/threshold misconceptions, WARN vs CRIT labels, finding/verdict codes
- [Payer-central dynamic budgets use case](./billing-dynamic-budgets-usecase.md) — sanitized architecture: management-account budgets/alerts, monthly Lambda refresh, open CloudWatch dynamism questions

## Scripts

- [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) — **read-only** two-round tool:
  1. `inventory` — WARN/CRIT list, linked-account pairing, WARN removal candidates
  2. `assess` — threshold sanity for **all** alarms vs last-month spend + AWS Budgets  

  Markdown reports are written with `-o/--output` (UTF-8 file); they are not printed to the terminal. See [`scripts/README.md`](./scripts/README.md).

## Related

- [auth/](../auth/README.md) — SSO / multi-account profiles for the central account
- [scripts/](../scripts/README.md) — other account-wide helpers
