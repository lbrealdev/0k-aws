# Eliminate EC2 instances

How to inventory and remove EC2 resources without leaving orphaned cost, backups, or access. For why termination leaves things behind, see [Why EC2 elimination matters](./elimination-explanation.md).

## Pre-elimination inventory

Use the helper script with the instance IDs you are eliminating. It correlates leftover volumes, snapshots, AMIs, and AWS Backup recovery points by instance/volume IDs and tags (works for terminated instances when leftovers remain).

For AWS Backup, the script uses `list-recovery-points-by-resource` against the instance ARN and each discovered volume ARN (not a full vault scan).

```shell
./scripts/ec2-inventory.sh -i <INSTANCE_ID> --region <REGION>
./scripts/ec2-inventory.sh -i <INSTANCE_ID_1>,<INSTANCE_ID_2> --profile <PROFILE> -f json
./scripts/ec2-inventory.sh -i <INSTANCE_ID_1> -i <INSTANCE_ID_2> -f csv
```

The script always writes a report directory (`report/ec2-inventory-<timestamp>/` by default):

- `-f json` (default) → `summary.json`
- `-f csv` → `instances.csv`, `volumes.csv`, `snapshots.csv`, `amis.csv`, `backup-recovery-points.csv`

Or gather the pieces manually with CLI (see also [`cli/ec2.md`](../cli/ec2.md), [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md), [`cli/ec2-ami.md`](../cli/ec2-ami.md)).

### 1. Instances

```shell
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Type:InstanceType,State:State.Name,Launch:LaunchTime}" \
  --output table
```

### 2. Volumes and DeleteOnTermination

```shell
aws ec2 describe-volumes \
  --query "Volumes[*].{ID:VolumeId,Size:Size,State:State,AZ:AvailabilityZone,Attached:Attachments[0].InstanceId,DeleteOnTerm:Attachments[0].DeleteOnTermination}" \
  --output table
```

For a specific instance:

```shell
aws ec2 describe-instances \
  --instance-ids <INSTANCE_ID> \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[*].{Device:DeviceName,Volume:Ebs.VolumeId,DeleteOnTermination:Ebs.DeleteOnTermination}" \
  --output table
```

### 3. EBS snapshots (account-owned)

```shell
OWNER_ID=$(aws sts get-caller-identity --query Account --output text)

aws ec2 describe-snapshots \
  --owner-ids "$OWNER_ID" \
  --query "Snapshots[*].{ID:SnapshotId,Volume:VolumeId,State:State,Start:StartTime,Size:VolumeSize,Desc:Description,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table
```

### 4. Owned AMIs and backing snapshots

```shell
OWNER_ID=$(aws sts get-caller-identity --query Account --output text)

aws ec2 describe-images \
  --owners "$OWNER_ID" \
  --query "sort_by(Images[*].{AMI:Name,ID:ImageId,Date:CreationDate,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}, &Date)" \
  --output table
```

List all snapshot IDs referenced by an AMI:

```shell
aws ec2 describe-images \
  --image-ids <AMI_ID> \
  --query "Images[0].BlockDeviceMappings[*].Ebs.SnapshotId" \
  --output text
```

### 5. Data Lifecycle Manager (DLM)

```shell
aws dlm get-lifecycle-policies \
  --query "Policies[*].{ID:PolicyId,Desc:Description,State:State,Type:PolicyType}" \
  --output table
```

Inspect a policy:

```shell
aws dlm get-lifecycle-policy --policy-id <POLICY_ID>
```

### 6. AWS Backup (EC2 / EBS)

The inventory script discovers recovery points with `list-recovery-points-by-resource` for known instance/volume ARNs. For manual checks, you can still list vaults and recovery points:

List vaults and recovery points (resource ARNs contain `ec2` or `ebs`):

```shell
aws backup list-backup-vaults --query "BackupVaultList[*].BackupVaultName" --output table

aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <VAULT_NAME> \
  --query "RecoveryPoints[?contains(ResourceArn, 'ec2') || contains(ResourceArn, 'ebs')].{Arn:RecoveryPointArn,Resource:ResourceArn,Created:CreationDate,Status:Status}" \
  --output table
```

List backup plans that may still protect EC2/EBS:

```shell
aws backup list-backup-plans \
  --query "BackupPlansList[*].{Name:BackupPlanName,Id:BackupPlanId,LastExecution:LastExecutionDate}" \
  --output table
```

For deeper manual vault inspection, per-recovery-point tag checks, and when a tag-based filter is worth adding, see [AWS Backup recovery points](./backup-recovery-points.md).

## Final backup procedure

Decide retention before terminate:

1. **Need relaunchable image?** Create an AMI via [`ec2-final-snapshot.sh --mode ami`](../scripts/ec2-final-snapshot.sh) (running instances reboot by default) or the CLI below.
2. **Need volume-level restore only?** Use `--mode volumes` (default) on the same helper, see [manual / final snapshots](./manual-snapshots.md).
3. **Already covered by AWS Backup / DLM?** Confirm recent successful recovery points before deleting compute.

### Create a final AMI

```shell
aws ec2 create-image \
  --instance-id <INSTANCE_ID> \
  --name "<Name>-$(date -u +%Y%m%d-%H%M%S)-final" \
  --description "Final AMI before EC2 elimination" \
  --no-reboot
```

Wait until available:

```shell
aws ec2 wait image-available --image-ids <AMI_ID>
```

### Snapshot a volume

```shell
aws ec2 create-snapshot \
  --volume-id <VOLUME_ID> \
  --description "Final snapshot before EC2 elimination" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=final-<VOLUME_ID>}]'
```

```shell
aws ec2 wait snapshot-completed --snapshot-ids <SNAPSHOT_ID>
```

## Termination checklist

- [ ] Inventory instances, volumes, snapshots, AMIs, DLM, AWS Backup
- [ ] Confirm which volumes have `DeleteOnTermination=true` vs `false`
- [ ] Create final AMI and/or snapshots if retention is required ([manual snapshots](./manual-snapshots.md) / [`ec2-final-snapshot.sh`](../scripts/ec2-final-snapshot.sh))
- [ ] Note Elastic IPs, ENIs, and security groups in use
- [ ] Check Auto Scaling groups / launch templates / load balancers that reference the instances
- [ ] Stop applications / drain traffic if needed
- [ ] Terminate instances
- [ ] Verify expected volumes were deleted; delete intentional leftovers only after restore testing
- [ ] Release unused Elastic IPs; delete unused ENIs
- [ ] Review whether DLM policies and AWS Backup selections should be disabled or updated
- [ ] Plan later cleanup of obsolete AMIs **and** their backing snapshots

### Terminate an instance

```shell
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
```

### Disable termination protection if needed

```shell
aws ec2 describe-instance-attribute \
  --instance-id <INSTANCE_ID> \
  --attribute disableApiTermination

aws ec2 modify-instance-attribute \
  --instance-id <INSTANCE_ID> \
  --no-disable-api-termination
```

## Post-cleanup and cost traps

### Unattached volumes

```shell
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query "Volumes[*].{ID:VolumeId,Size:Size,AZ:AvailabilityZone,Create:CreateTime}" \
  --output table
```

### Unused Elastic IPs

```shell
aws ec2 describe-addresses \
  --query "Addresses[?AssociationId==null].{PublicIp:PublicIp,AllocationId:AllocationId}" \
  --output table
```

### Deregister an AMI (snapshots remain)

```shell
aws ec2 deregister-image --image-id <AMI_ID>
```

Then delete backing snapshots only if nothing else needs them:

```shell
aws ec2 delete-snapshot --snapshot-id <SNAPSHOT_ID>
```

### Snapshot retention

Manual snapshots persist until deleted and incur storage cost. Set a reminder to remove final backups once migration/restore confidence is high.

## Related

- [Why EC2 elimination matters](./elimination-explanation.md): resource map and backup trade-offs
- [AWS Backup recovery points](./backup-recovery-points.md): recovery-point filter reference
- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh): instance-scoped JSON/CSV report (`--instance` required; `-f json|csv`)

## References

- [AWS CLI EC2 Reference](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- [Amazon EBS snapshots](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-snapshots.html)
- [AMI lifecycle](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMILifecycle.html)
- [Data Lifecycle Manager](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)
- [AWS Backup for EC2](https://docs.aws.amazon.com/aws-backup/latest/devguide/ec2-backup.html)
- [terminate-instances](https://docs.aws.amazon.com/cli/latest/reference/ec2/terminate-instances.html)
