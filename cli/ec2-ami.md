# EC2 AMI

List AMI names by pattern, newest first:
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query 'reverse(sort_by(Images[*], &CreationDate)[].Name)' \
  --output table
```

Get the latest AMI ID:
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query 'sort_by(Images[*], &CreationDate)[-1].[ImageId]' \
  --output table
```

List AMI properties by pattern (table, newest first):
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query "sort_by(Images[*].{AMI:Name,ID:ImageId,Owner:OwnerId,Date:CreationDate,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}, &Date)" \
  --output table
```

## Related

- [EC2 Elimination](../ec2/elimination.md) — AMI retention and backing snapshot cleanup
- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh) — JSON/CSV report of AMIs related to specific instance IDs
