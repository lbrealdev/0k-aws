# CloudWatch

Operational guides and read-only helpers for Amazon CloudWatch — especially **centralized billing alarms** (WARN/CRIT) that represent many linked accounts.

## Guides

- [Billing alarm misconfigurations](./billing-alarm-misconfigurations.md) — MTD/threshold misconceptions, WARN vs CRIT policy, finding/verdict codes

## Scripts

- [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) — **read-only** two-round tool:
  1. `inventory` — WARN/CRIT list, linked-account pairing, WARN removal candidates
  2. `assess` — threshold sanity for **all** alarms vs last-month spend + AWS Budgets  

  Markdown reports are written with `-o/--output` (UTF-8 file); they are not printed to the terminal. See [`scripts/README.md`](./scripts/README.md).

## Related

- [auth/](../auth/README.md) — SSO / multi-account profiles for the central account
- [scripts/](../scripts/README.md) — other account-wide helpers
