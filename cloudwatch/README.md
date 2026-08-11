# CloudWatch

Operational guides and read-only helpers for Amazon CloudWatch — especially billing alarms that often fire across management and OU/shared accounts.

## Scripts

- [`scripts/analyze-billing-alarms.py`](./scripts/analyze-billing-alarms.py) — **read-only** analysis of `AWS/Billing` / `EstimatedCharges` alarms (misconfiguration and noise). See [`scripts/README.md`](./scripts/README.md).

## Related

- [auth/](../auth/README.md) — SSO / multi-account profiles used with `-p` / `--profiles`
- [scripts/](../scripts/README.md) — other account-wide helpers
