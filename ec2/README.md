# EC2

Operational guides and good practices for day-to-day Amazon EC2 work: inventory, backups, snapshots, and cleanup.

## Guides

- [Manual / final snapshots](./manual-snapshots.md): when and how to take intentional EBS snapshots before risky changes
- [Eliminate EC2 instances](./elimination.md): inventory, backups, and termination checklist for removing EC2 resources safely
  - [Why EC2 elimination matters](./elimination-explanation.md): resource map and backup trade-offs
  - [AWS Backup recovery points](./backup-recovery-points.md): recovery-point filter reference
- [Windows on EC2](./windows/README.md): patch state on Windows Server instances
  - [Updates](./windows/updates.md): installed KBs, pending updates, pending reboot

## Related CLI references

- [`cli/ec2.md`](../cli/ec2.md): list instances
- [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md): list EBS snapshots
- [`cli/ec2-ami.md`](../cli/ec2-ami.md): list and find AMIs
- [`cli/security-groups.md`](../cli/security-groups.md): security groups
- [`cli/vpc.md`](../cli/vpc.md): VPC-related commands

## Related Scripts

- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh): read-only, instance-scoped JSON/CSV report (volumes, snapshots, AMIs, DLM, AWS Backup)
- [`scripts/ec2-final-snapshot.sh`](../scripts/ec2-final-snapshot.sh): create final/manual volume snapshots or AMIs for live instances (**write**; `--mode volumes|ami`)
