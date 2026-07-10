# Scripts

Helper scripts for common AWS operational tasks.

Convention: prefer **read-only** helpers for inventory/discovery. Write helpers should support `--dry-run` where practical and make side effects obvious.

## Index

| Script | Mode | Purpose | Related docs |
|--------|------|---------|--------------|
| [`ec2-inventory.sh`](./ec2-inventory.sh) | Read-only | Instance-scoped inventory of volumes, snapshots, AMIs, DLM policies, and AWS Backup recovery points (JSON/CSV report) | [EC2 Elimination](../ec2/ec2-elimination.md), [ec2/](../ec2/README.md) |
| [`list-resources.sh`](./list-resources.sh) | Read-only | List account resources via Resource Groups Tagging API (profiles/regions, optional report) | [AWS List Resources](../aws-list-resources/README.md) |
| [`s3-bucket-object.sh`](./s3-bucket-object.sh) | Read-only | List S3 buckets and object counts | [cli/s3.md](../cli/s3.md) |
| [`rds-modify-snapshot.sh`](./rds-modify-snapshot.sh) | **Write** | Batch-modify RDS DB snapshot option groups (supports `--dry-run`) | [RDS Deletion](../databases/rds-deletion.md), [databases/](../databases/README.md) |

## Relationships

- **EC2 inventory vs future snapshot helper:** `ec2-inventory.sh` only reports what exists. Creating final/manual EBS snapshots before a change is a separate write workflow (tracked as a future helper; see issue discussions around EC2 final snapshots).
- **RDS:** `rds-modify-snapshot.sh` changes snapshot metadata (option groups); it does not delete instances. Pair with the RDS deletion guide when planning teardown.
- **Discovery:** `list-resources.sh` is account-wide tagging-API discovery; `ec2-inventory.sh` is deep and instance-scoped.

## Usage notes

- Requires AWS CLI (and `jq` where noted by each script).
- Pass `--profile` / `--region` (or configure defaults) as documented in each script’s `--help`.
- Always prefer `--dry-run` on write scripts before applying changes.
