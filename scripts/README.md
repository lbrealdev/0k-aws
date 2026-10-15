# Scripts

Helper scripts for common AWS operational tasks.

Names follow `aws-<domain>-<thing>.sh` or `.py`. Domain is the AWS service (`ec2`, `rds`, `s3`, `iam`, `sso`, `codecommit`, `cloudwatch`). Tools that span services use `account`. `csv-to-xlsx.py` is a local converter and has no `aws-` prefix.

Convention: prefer **read-only** helpers for inventory/discovery. Write helpers should support `--dry-run` where practical and make side effects obvious.

## Index

| Script | Mode | Purpose | Related docs |
|--------|------|---------|--------------|
| [`aws-account-list-resources.sh`](./aws-account-list-resources.sh) | Read-only | List account resources via Resource Groups Tagging API (profiles/regions, optional report) | [List Resources](../list-resources/README.md) |
| [`aws-cloudwatch-account-billing.py`](./aws-cloudwatch-account-billing.py) | Read-only | Per-account review: hub CloudWatch + Budgets, target Cost Explorer, plain-text NORMAL/ABNORMAL | [CloudWatch](../cloudwatch/README.md) |
| [`aws-cloudwatch-billing-alarms.py`](./aws-cloudwatch-billing-alarms.py) | Read-only | Inventory then assess payer billing alarms (`inventory`, `assess`) | [CloudWatch](../cloudwatch/README.md) |
| [`aws-codecommit-gitconfig.sh`](./aws-codecommit-gitconfig.sh) | **Write** | Git Bash helper for CodeCommit HTTPS; check-only unless `--fix-system` or `--migrate` | [CodeCommit](../dev-tools/codecommit/README.md) |
| [`aws-devtools-report.sh`](./aws-devtools-report.sh) | Read-only | CSV reports for CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline | [Dev tools scripts](../dev-tools/scripts/README.md) |
| [`aws-ec2-final-snapshot.sh`](./aws-ec2-final-snapshot.sh) | **Write** | Final backups for live instances: `--mode volumes` or `--mode ami`; supports `--dry-run` | [Manual snapshots](../ec2/manual-snapshots.md), [EC2 Elimination](../ec2/elimination.md) |
| [`aws-ec2-inventory.sh`](./aws-ec2-inventory.sh) | Read-only | Instance-scoped inventory of volumes, snapshots, AMIs, DLM policies, and AWS Backup recovery points | [EC2 Elimination](../ec2/elimination.md), [Manual snapshots](../ec2/manual-snapshots.md), [ec2/](../ec2/README.md) |
| [`aws-ec2-sg-audit.sh`](./aws-ec2-sg-audit.sh) | Read-only | Ingress rules open to `0.0.0.0/0` or `::/0`, with a SENSITIVE flag for watched ports | [cli/security-groups.md](../cli/security-groups.md) |
| [`aws-iam-find-role.sh`](./aws-iam-find-role.sh) | Read-only | Find an IAM role (substring or exact name) across SSO profiles | [cli/iam.md](../cli/iam.md) |
| [`aws-rds-modify-snapshot.sh`](./aws-rds-modify-snapshot.sh) | **Write** | Batch-modify RDS DB snapshot option groups (supports `--dry-run`) | [RDS Deletion](../rds/deletion.md), [rds/](../rds/README.md) |
| [`aws-rds-snapshot-age.sh`](./aws-rds-snapshot-age.sh) | Read-only | Instance and cluster snapshots with age in days; flag older than `--min-age` | [RDS Deletion](../rds/deletion.md), [rds/](../rds/README.md) |
| [`aws-s3-bucket-object.sh`](./aws-s3-bucket-object.sh) | Read-only | List S3 buckets and object counts | [cli/s3.md](../cli/s3.md) |
| [`aws-sso-check.sh`](./aws-sso-check.sh) | Read-only | Validate SSO profiles; `--check-config` / `--check-env` for local inspection | [SSO](../auth/sso.md) |
| [`csv-to-xlsx.py`](./csv-to-xlsx.py) | Local | Convert generated CSVs into one XLSX workbook | [Dev tools scripts](../dev-tools/scripts/README.md) |

## Relationships

- **EC2 inventory vs final snapshots:** `aws-ec2-inventory.sh` only reports what exists. `aws-ec2-final-snapshot.sh` creates intentional volume snapshots and/or AMIs before a change (does not terminate or delete).
- **RDS:** `aws-rds-modify-snapshot.sh` changes snapshot metadata (option groups); it does not delete instances. Pair with the RDS deletion guide when planning teardown. `aws-rds-snapshot-age.sh` is read-only inventory of leftover/old snapshots.
- **Discovery:** `aws-account-list-resources.sh` is account-wide tagging-API discovery; `aws-ec2-inventory.sh` is deep and instance-scoped. `aws-ec2-sg-audit.sh` is a narrow world-open ingress check.

## Usage notes

- Requires AWS CLI (and `jq` where noted by each script).
- Pass `--profile` / `--region` (or configure defaults) as documented in each script’s `--help`.
- On write scripts, run `--dry-run` before applying changes.
- Status output follows `scripts/lib/ui.sh`: banner/header and status rows go to stderr, pipeable data goes to stdout, `-q` / `--quiet` drops the non-error rows, and color appears only on a TTY with `NO_COLOR` unset. Each script resolves `scripts/lib/ui.sh` from its own path, so copy `scripts/lib/` alongside the script if you move it (for example into CloudShell).
