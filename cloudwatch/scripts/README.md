# cloudwatch/scripts

## `analyze-billing-alarms.py`

Read-only **two-round** tool for centralized CloudWatch billing alarms (`AWS/Billing` / `EstimatedCharges`):

1. **`inventory`** — list alarms, classify `WARN` / `CRIT`, map linked accounts, mark WARN as removal candidates.
2. **`assess`** — for **all** inventory alarms, compare thresholds to last-month spend + AWS Budgets (live AWS data only).

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
# Round 1 - write inventory JSON (and optional markdown report)
./cloudwatch/scripts/analyze-billing-alarms.py inventory \
  -p <central> -r us-east-1 -f json -o billing-inventory.json
./cloudwatch/scripts/analyze-billing-alarms.py inventory \
  -p <central> -f markdown -o inventory.md

# Round 2 - assess all alarms; markdown must go to a file
./cloudwatch/scripts/analyze-billing-alarms.py assess \
  -p <central> -r us-east-1 --from billing-inventory.json -f markdown -o assessment.md
```

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| (subcommand) | | required | `inventory` or `assess` |
| `--profile` | `-p` | required | Central AWS profile |
| `--region` | `-r` | env / `us-east-1` | AWS region |
| `--format` | `-f` | `table` | `table` \| `json` \| `markdown` |
| `--output` | `-o` | — | Write report to PATH (UTF-8). **Required for markdown** |
| `--from` | | required for `assess` | Inventory JSON from `inventory -f json` |
| `--help` | `-h` | | Show help |

**Output rules**

- `-f markdown` never prints the report body to the terminal; it requires `-o/--output`.
- `-f table` prints to stdout (human skim).
- `-f json` prints to stdout unless `-o` is set (then file only).
- Progress logs go to stderr (`-> …`).

### Pairing and signals

- **Severity:** `WARN` / `CRIT` substring in the alarm name.
- **Linked account:** `LinkedAccount` dimension, else first 12-digit id in the alarm name.
- **Spend (assess):** previous calendar month **max** `EstimatedCharges` for that linked account (from the central profile).
- **Budget (assess):** budgets in the central account matched by CostFilters / name containing the account id.
- **suggested_crit:** per row, only when peak and/or budget exist: `max(last_month_peak, budget_limit) * 1.1`.

Reports use **live AWS values only** (no hard-coded example dollar amounts).

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed (findings/verdicts in output only) |
| 1 | Usage error |
| 2 | AWS error |

---

## `review-account-billing.py`

Read-only **per-account** review using **two named SSO profiles** (not env credentials):

1. **Hub (`--hub`)** — payer account: CloudWatch billing alarms + Budgets for the member  
2. **Account (`-a` / `--account`)** — Cost Explorer UnblendedCost for last 1/3/6 complete months + MTD (1st → today)

`--hub` and `--account` are SSO profile names, not account ids. The script does **not** use `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`; if those are set it exits with a usage error (boto3 would otherwise let them override the profiles, and env creds cannot select two accounts).

Prints a **plain-text** report on stdout with verdict `NORMAL` / `ABNORMAL` / `INSUFFICIENT_DATA`. No `-f` / markdown / `-o` in v1.

Implemented as a uv inline script with `boto3`.

### Prerequisites

- [`uv`](https://docs.astral.sh/uv/)
- SSO login for hub and member profiles (`aws sso login --profile …`)
- IAM:
  - Hub: `sts:GetCallerIdentity`, `cloudwatch:DescribeAlarms`, `budgets:ViewBudget` / `DescribeBudgets`
  - Account: `sts:GetCallerIdentity`, `ce:GetCostAndUsage`

### Usage

```bash
./cloudwatch/scripts/review-account-billing.py --hub hub --account project-a

# Optional: focus budgets whose name contains a substring
./cloudwatch/scripts/review-account-billing.py --hub hub --account project-a --budget Breached
```

CloudWatch billing metrics, Budgets, and Cost Explorer calls always use **`us-east-1`** (no `--region`).

On a TTY, a one-line spinner runs on stderr while AWS calls are in flight, then disappears. The report is the only stdout. Piped/non-TTY runs stay silent until the report or an error.

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--hub` | | required | Hub (payer) SSO profile |
| `--account` | `-a` | required | Member account SSO profile |
| `--months` | | `6` | Complete months of CE history |
| `--budget` | | — | Substring filter on budget name |
| `--color` | | `auto` | ANSI color: `auto` (TTY only), `always`, or `never` |
| `--help` | `-h` | | Show help |

Profiles only select accounts; alarms, budgets, and spend are **discovered** for the member account id from STS.

### Verdict (v1)

Using complete-month UnblendedCost series (up to `--months`):

- **ABNORMAL** if any month is > 1.5x or < 0.5x the median (when median > 0)
- **NORMAL** otherwise
- **INSUFFICIENT_DATA** if fewer than 2 months of data

MTD vs budget limit is shown for information; it does not alone force ABNORMAL.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Completed |
| 1 | Usage error |
| 2 | AWS error |
