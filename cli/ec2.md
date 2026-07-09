# EC2

List EC2 instances by filtering by tag:name value with queries to display some reverse sort data fields for runtime with table output format:
```shell
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=<instance-name>" \
  --filters "Name=instance-state-name,Values=<instance-state>" \
  --query "reverse(sort_by(Reservations[*].Instances[].{ID:InstanceId,Type:InstanceType,Status:State.Name,Init:LaunchTime,EC2Name:Tags[?Key == 'Name'].Value | [0]} &Init))" \
  --output table
```

## Related

- [EC2 Elimination](../ec2/ec2-elimination.md) — inventory, backups, and termination checklist
- [`scripts/ec2-backup-inventory.sh`](../scripts/ec2-backup-inventory.sh) — instance-scoped backup/elimination inventory (`-i` required)
