# Scripts

Helper scripts for common AWS operational tasks.

Convention: prefer **read-only** helpers for inventory/discovery. Write helpers should support `--dry-run` where practical and make side effects obvious.

## Index

| Script | Mode | Purpose | Related docs |
|--------|------|---------|--------------|
| [`ec2-inventory.sh`](./ec2-inventory.sh) | Read-only | Instance-scoped inventory of volumes, snapshots, AMIs, DLM policies, and AWS Backup recovery points (JSON/CSV report) | [EC2 Elimination](../ec2/elimination.md), [Manual snapshots](../ec2/manual-snapshots.md), [ec2/](../ec2/README.md) |
| [`ec2-final-snapshot.sh`](./ec2-final-snapshot.sh) | **Write** | Final backups for live instances: `--mode volumes` (`create-snapshots`, copy volume tags) or `--mode ami` (`create-image`, copy instance tags + Purpose/--tag, reboot by default for running instances); supports `--dry-run` | [Manual snapshots](../ec2/manual-snapshots.md), [EC2 Elimination](../ec2/elimination.md) |
| [`list-resources.sh`](./list-resources.sh) | Read-only | List account resources via Resource Groups Tagging API (profiles/regions, optional report) | [List Resources](../list-resources/README.md) |
| [`s3-bucket-object.sh`](./s3-bucket-object.sh) | Read-only | List S3 buckets and object counts | [cli/s3.md](../cli/s3.md) |
| [`s3-find-state.py`](./s3-find-state.py) | Read-only | Find which S3 bucket holds an exact object key (e.g. Terraform state) | [cli/s3.md](../cli/s3.md) |
| [`rds-modify-snapshot.sh`](./rds-modify-snapshot.sh) | **Write** | Batch-modify RDS DB snapshot option groups (supports `--dry-run`) | [RDS Deletion](../rds/deletion.md), [rds/](../rds/README.md) |
| [`sg-audit.sh`](./sg-audit.sh) | Read-only | Ingress rules open to `0.0.0.0/0` or `::/0`, with a SENSITIVE flag for watched ports | [cli/security-groups.md](../cli/security-groups.md) |
| [`rds-snapshot-age.sh`](./rds-snapshot-age.sh) | Read-only | Instance and cluster snapshots with age in days; flag older than `--min-age` | [RDS Deletion](../rds/deletion.md), [rds/](../rds/README.md) |

## Relationships

- **EC2 inventory vs final snapshots:** `ec2-inventory.sh` only reports what exists. `ec2-final-snapshot.sh` creates intentional volume snapshots and/or AMIs before a change (does not terminate or delete).
- **RDS:** `rds-modify-snapshot.sh` changes snapshot metadata (option groups); it does not delete instances. Pair with the RDS deletion guide when planning teardown. `rds-snapshot-age.sh` is read-only inventory of leftover/old snapshots.
- **Discovery:** `list-resources.sh` is account-wide tagging-API discovery; `ec2-inventory.sh` is deep and instance-scoped. `sg-audit.sh` is a narrow world-open ingress check. `s3-find-state.py` locates one exact object key across buckets; `s3-bucket-object.sh` lists buckets and object counts.

## `s3-find-state.py`

Read-only: given an exact object key (typical Terraform `backend "s3"` `key`), list buckets in **one** account and print which bucket(s) hold that object. Bucket/region are discovered; the account is selected with `-p/--profile` (SSO).

```bash
uv run scripts/s3-find-state.py --key env/prod/terraform.tfstate -p my-sso
uv run scripts/s3-find-state.py --key env/prod/terraform.tfstate --prefix tfstate- -p my-sso
```

Stdout is pipeable (`bucket  key` per match). Progress and "none found" go to stderr. AccessDenied on a bucket is noted on stderr; the scan continues.

IAM: `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:GetObject` / `s3:ListBucket`.

| Code | Meaning |
|------|---------|
| 0 | Completed (including zero matches) |
| 1 | Usage error |
| 2 | AWS error |

If `-p/--profile` is set, unset `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` (boto3 would let env override the profile). Requires [`uv`](https://docs.astral.sh/uv/).

## Usage notes

- Requires AWS CLI (and `jq` where noted by each script). Python helpers need `uv`.
- Pass `--profile` / `--region` (or configure defaults) as documented in each script’s `--help`.
- Always prefer `--dry-run` on write scripts before applying changes.
