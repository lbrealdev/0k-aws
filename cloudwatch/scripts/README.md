# cloudwatch/scripts

## `analyze-billing-alarms.py`

Read-only **two-round** tool for centralized CloudWatch billing alarms (`AWS/Billing` / `EstimatedCharges`):

1. **`inventory`** — list alarms, classify `WARN` / `CRIT`, map linked accounts, mark WARN as removal candidates.
2. **`assess`** — for CRIT only, compare thresholds to last-month spend + AWS Budgets.

Implemented as a [uv inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies) (PEP 723) with `boto3`.

Billing metrics are only published in **`us-east-1`**. Prefer `-r us-east-1`.

Concepts and failure codes: [`../billing-alarm-misconfigurations.md`](../billing-alarm-misconfigurations.md).

### Prerequisites

- [`uv`](https://docs.astral.sh/uv/)
- SSO / AWS credentials for the **central** profile (account that holds the alarms)
- IAM:
  - `sts:GetCallerIdentity`
  - `cloudwatch:DescribeAlarms`
  - `cloudwatch:GetMetricData` (assess)
  - `budgets:ViewBudget` / `budgets:DescribeBudgets` (assess)

### Usage

```bash
# Round 1
./cloudwatch/scripts/analyze-billing-alarms.py inventory -p <central> -r us-east-1 -f json > billing-inventory.json

# Round 2
./cloudwatch/scripts/analyze-billing-alarms.py assess -p <central> -r us-east-1 --from billing-inventory.json -f markdown
```

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| (subcommand) | | required | `inventory` or `assess` |
| `--profile` | `-p` | required | Central AWS profile |
| `--region` | `-r` | env / `us-east-1` | AWS region |
| `--format` | `-f` | `table` | `table` \| `json` \| `markdown` |
| `--from` | | required for `assess` | Inventory JSON from `inventory -f json` |
| `--help` | `-h` | | Show help |

### Pairing and signals

- **Severity:** `WARN` / `CRIT` substring in the alarm name.
- **Linked account:** `LinkedAccount` dimension, else first 12-digit id in the alarm name.
- **Spend (assess):** previous calendar month **max** `EstimatedCharges` for that linked account (from the central profile).
- **Budget (assess):** budgets in the central account matched by CostFilters / name containing the account id.

### Examples

```bash
./cloudwatch/scripts/analyze-billing-alarms.py inventory -p master -r us-east-1
./cloudwatch/scripts/analyze-billing-alarms.py inventory -p master -f json > billing-inventory.json
./cloudwatch/scripts/analyze-billing-alarms.py assess -p master --from billing-inventory.json -f table
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed (findings/verdicts in output only) |
| 1 | Usage error |
| 2 | AWS error |
