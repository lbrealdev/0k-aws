# EC2

Operational guides for Amazon EC2 elimination, backups, and related cleanup.

## Guides

- [EC2 Elimination](./ec2-elimination.md) — inventory, snapshots, AMIs, backups, and checklist for removing EC2 resources safely

## Related CLI references

- [`cli/ec2.md`](../cli/ec2.md) — list instances
- [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md) — list EBS snapshots
- [`cli/ec2-ami.md`](../cli/ec2-ami.md) — list and find AMIs
- [`cli/security-groups.md`](../cli/security-groups.md) — security groups
- [`cli/vpc.md`](../cli/vpc.md) — VPC-related commands

## Related Scripts

- [`scripts/ec2-backup-inventory.sh`](../scripts/ec2-backup-inventory.sh) — read-only inventory of instances, volumes, snapshots, AMIs, DLM policies, and AWS Backup recovery points
