# cloudwatch/scripts

## `analyze-billing-alarms.py`

Read-only analysis of CloudWatch **billing** alarms (`AWS/Billing` / `EstimatedCharges`) across one or more AWS profiles. Flags common misconfiguration and noise (low thresholds, missing Currency, broken SNS, unexpected metric shape, cross-account duplicates).

Implemented as a [uv inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies) (PEP 723) with `boto3`.

Billing metrics are only published in **`us-east-1`**. Prefer `-r us-east-1`.

### Prerequisites

- [`uv`](https://docs.astral.sh/uv/)
- AWS credentials (boto3 chain / SSO profiles)
- IAM: `sts:GetCallerIdentity`, `cloudwatch:DescribeAlarms`, `sns:ListSubscriptionsByTopic`

### Usage

```bash
./cloudwatch/scripts/analyze-billing-alarms.py -p <profile> -r us-east-1 [options]
```

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--profile` | `-p` | — | AWS profile name |
| `--profiles` | | — | Comma-separated profiles |
| `--region` | `-r` | env / `us-east-1` | AWS region |
| `--format` | `-f` | `table` | `table` \| `json` \| `markdown` |
| `--min-threshold` | | `10` | Warn when threshold ≤ this (USD) |
| `--help` | `-h` | | Show help |

At least one of `-p/--profile` or `--profiles` is required.

### Examples

```bash
./cloudwatch/scripts/analyze-billing-alarms.py -p master -r us-east-1
./cloudwatch/scripts/analyze-billing-alarms.py --profiles master,shared -f json
./cloudwatch/scripts/analyze-billing-alarms.py -p shared -f markdown --min-threshold 50
```

### Finding codes

| Code | Severity | Meaning |
|------|----------|---------|
| `WRONG_REGION` | error | Scan region is not `us-east-1` |
| `MISSING_CURRENCY` | error | No `Currency` dimension |
| `UNEXPECTED_SHAPE` | warn | Not `EstimatedCharges` + `Maximum` + `GreaterThanOrEqualToThreshold` |
| `LOW_THRESHOLD` | warn | Threshold ≤ `--min-threshold` |
| `NO_ACTIONS` | error | No `AlarmActions` |
| `SNS_TOPIC_MISSING` | error | SNS topic missing / inaccessible |
| `SNS_NO_SUBSCRIPTIONS` | error | Topic has no subscriptions |
| `SNS_UNCONFIRMED` | error | Subscription pending confirmation |
| `STATE_IN_ALARM` | warn | Currently in `ALARM` |
| `DUPLICATE_CROSS_ACCOUNT` | warn | Same billing shape/threshold in multiple scanned accounts |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Scan completed (findings are reported in output only) |
| 1 | Usage error |
| 2 | AWS error |
