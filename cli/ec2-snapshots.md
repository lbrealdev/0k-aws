# EC2 Snapshots

List completed snapshots you own (ID and Name tag):
```shell
aws ec2 describe-snapshots \
  --filters "Name=status,Values=completed" \
  --filters "Name=owner-id,Values=<owner-id>" \
  --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key == 'Name'].Value | [0]}" \
  --output table
```

## Related

- [EC2 Elimination](../ec2/elimination.md): snapshots vs AMIs vs AWS Backup vs DLM
- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh): JSON/CSV report of snapshots related to specific instance IDs
