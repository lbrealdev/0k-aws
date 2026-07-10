# EC2

Operational guides and good practices for day-to-day Amazon EC2 work — inventory, backups, snapshots, and cleanup.

## Guides

- [Manual / final snapshots](./manual-snapshots.md) — when and how to take intentional EBS snapshots before risky changes
- [EC2 Elimination](./ec2-elimination.md) — inventory, snapshots, AMIs, backups, and checklist for removing EC2 resources safely
  - Includes [Investigate recovery points](./ec2-elimination.md#investigate-recovery-points-before-adding-a-backup-filter) before adding any Backup filter

## Related CLI references

- [`cli/ec2.md`](../cli/ec2.md) — list instances
- [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md) — list EBS snapshots
- [`cli/ec2-ami.md`](../cli/ec2-ami.md) — list and find AMIs
- [`cli/security-groups.md`](../cli/security-groups.md) — security groups
- [`cli/vpc.md`](../cli/vpc.md) — VPC-related commands

## Related Scripts

- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh) — read-only, instance-scoped JSON/CSV report (volumes, snapshots, AMIs, DLM, AWS Backup)
- [`scripts/ec2-final-snapshot.sh`](../scripts/ec2-final-snapshot.sh) — create final/manual volume snapshots or AMIs for live instances (**write**; `--mode volumes|ami`)
