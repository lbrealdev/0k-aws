# EC2 AMI

List all AMIs by filtering by name and sort the query by the creation date of all images.:
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

List all AMIs by filtering by name, passing query in table format output with some AMI properties.
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query "sort_by(Images[*].{AMI:Name,ID:ImageId,Owner:OwnerId,Date:CreationDate,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}, &Date)" \
  --output table
```
