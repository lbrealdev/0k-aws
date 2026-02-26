# EC2 Snapshots

List all snapshots filtering by owner id and snapshot status passing query by snapshot id and tag key:
```shell
aws ec2 describe-snapshots \
  --filters "Name=status,Values=completed" \
  --filters "Name=owner-id,Values=<owner-id>" \
  --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key == 'Name'].Value | [0]}" \
  --output table
```
