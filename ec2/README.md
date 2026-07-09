# EC2

Operational guides for Amazon EC2 elimination, backups, and related cleanup.

## Guides

- [EC2 Elimination](./ec2-elimination.md) — inventory, snapshots, AMIs, backups, and checklist for removing EC2 resources safely
  - Includes [Investigate recovery points](./ec2-elimination.md#investigate-recovery-points-before-adding-a-backup-filter) before adding any Backup filter

## Related CLI references

- [`cli/ec2.md`](../cli/ec2.md) — list instances
- [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md) — list EBS snapshots
- [`cli/ec2-ami.md`](../cli/ec2-ami.md) — list and find AMIs
- [`cli/security-groups.md`](../cli/security-groups.md) — security groups
- [`cli/vpc.md`](../cli/vpc.md) — VPC-related commands

## Related Scripts

- [`scripts/ec2-backup-inventory.sh`](../scripts/ec2-backup-inventory.sh) — read-only, instance-scoped JSON/CSV report generator for volumes, snapshots, AMIs, DLM, and AWS Backup
