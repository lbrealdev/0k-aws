# EC2 Elimination

Terminating EC2 instances is not the same as eliminating EC2 cost and risk. Volumes, snapshots, AMIs, Elastic IPs, ENIs, DLM policies, and AWS Backup recovery points can remain after instances are gone.

This guide covers what to inventory, how backups relate to each other, and a practical checklist before and after termination.

## Why this matters

- **Termination is irreversible** for the instance itself. Recovery depends on AMIs/snapshots/AWS Backup you kept beforehand.
- **Root volumes** are often deleted with the instance (`DeleteOnTermination=true` by default for the root device).
- **Data volumes**, snapshots, and AMIs frequently survive and keep billing.
- **AMI deregister** does not delete the EBS snapshots that back the AMI.

## Resource map

| Resource | What it is | Survives instance terminate? | Notes |
|----------|------------|------------------------------|-------|
| **EBS volume** | Block storage attached to an instance | Depends on `DeleteOnTermination` | Unattached volumes keep costing money |
| **EBS snapshot** | Point-in-time copy of a volume | Yes | Manual, DLM, or AWS Backup–related copies |
| **AMI** | Launchable image of an instance | Yes | Backed by one or more snapshots |
| **AWS Backup recovery point** | Vaulted backup of EC2/EBS | Yes | Managed outside the EC2 Snapshots console view |
| **DLM policy** | Lifecycle schedule for snapshots/AMIs | Policy remains | Can keep creating or retaining backups |
| **ENI / EIP / SG** | Networking around the instance | Often yes | Orphans are common after terminate |
| **Launch template / ASG / ELB** | Orchestration around EC2 | Yes | May recreate or block clean removal |

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

### Investigate recovery points (before adding a Backup filter)

Do **not** assume a tag-based Backup filter will help. Start with what `list-recovery-points-by-backup-vault` actually returns.

Important: that API does **not** include a `Tags` attribute on recovery points. See the [API reference](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_ListRecoveryPointsByBackupVault.html) and [CLI reference](https://docs.aws.amazon.com/cli/latest/reference/backup/list-recovery-points-by-backup-vault.html). Useful server-side filters include `--by-resource-arn`, `--by-resource-type`, and `--by-backup-plan-id`.

#### 1. List vaults

```shell
aws backup list-backup-vaults \
  --query 'BackupVaultList[].BackupVaultName' \
  --output table
```

#### 2. Inspect recovery points in one vault

```shell
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <VAULT_NAME> \
  --output json | jq '.RecoveryPoints[] | {
    recoveryPointArn: .RecoveryPointArn,
    resourceArn: .ResourceArn,
    resourceType: .ResourceType,
    status: .Status,
    created: .CreationDate,
    backupPlanId: (.CreatedBy.BackupPlanId // null),
    backupPlanName: (.CreatedBy.BackupPlanName // null)
  }'
```

#### 3. Focus on EC2 / EBS recovery points

Prefer the API filter when possible:

```shell
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <VAULT_NAME> \
  --by-resource-type EC2 \
  --output json | jq '.RecoveryPoints[] | {
    recoveryPointArn: .RecoveryPointArn,
    resourceArn: .ResourceArn,
    status: .Status,
    created: .CreationDate,
    backupPlanId: (.CreatedBy.BackupPlanId // null)
  }'
```

```shell
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <VAULT_NAME> \
  --by-resource-type EBS \
  --output json | jq '.RecoveryPoints[] | {
    recoveryPointArn: .RecoveryPointArn,
    resourceArn: .ResourceArn,
    status: .Status,
    created: .CreationDate,
    backupPlanId: (.CreatedBy.BackupPlanId // null)
  }'
```

Or target one known resource ARN:

```shell
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <VAULT_NAME> \
  --by-resource-arn arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/<INSTANCE_ID> \
  --output json | jq '.RecoveryPoints[] | {
    recoveryPointArn: .RecoveryPointArn,
    resourceArn: .ResourceArn,
    status: .Status,
    created: .CreationDate
  }'
```

#### 4. Optional: inspect tags on a single recovery point

Tags are not returned by `list-recovery-points-by-backup-vault`. Fetch them per recovery point with `list-tags`:

```shell
aws backup list-tags \
  --resource-arn <RECOVERY_POINT_ARN> \
  --output json
```

Repeat for a sample of EC2/EBS recovery points and look for a common key/value. Only if that pattern is stable is a future tag-based filter worth considering.

#### Decision rule

| Finding | Action |
|---------|--------|
| Recovery points are easy to target by resource ARN / resource type / backup plan ID | Prefer those filters; no tag flag needed |
| `list-tags` shows a common key + stable value on recovery points | A tag-based filter flag may be worth adding later |
| Tags empty, inconsistent, or only on the source instance/volume | Do not add a tag filter; prefer ARN-based discovery |

Script default path:

1. [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh) uses `list-recovery-points-by-resource` for the instance ARN and each volume ARN (fast, no vault scan, no tag assumptions)
2. Optional later: a tag-based approach **only if** step 4 confirms a useful recovery-point tag

Manual vault inspection above remains useful for exploration; it is not how the helper discovers recovery points.

## Snapshots vs AMIs vs AWS Backup vs DLM

These are related but not interchangeable:

- **EBS snapshot** — backup of a single volume. Fastest primitive for volume restore.
- **AMI** — package of instance configuration + one or more snapshots. Needed to relaunch an instance image cleanly.
- **DLM** — automation that creates/retains/deletes snapshots or AMIs on a schedule. Disabling/deleting instances does not remove the policy.
- **AWS Backup** — organization-friendly backup plans and vaults. Recovery points may appear as snapshots in EC2, but lifecycle is controlled by Backup (especially when vault lock / retention rules apply).

For elimination projects, inventory **all four**. Keeping only “EC2 console snapshots” is incomplete.

## Final backup procedure

Decide retention before terminate:

1. **Need relaunchable image?** Create an AMI via [`ec2-final-snapshot.sh --mode ami`](../scripts/ec2-final-snapshot.sh) (running instances reboot by default) or the CLI below.
2. **Need volume-level restore only?** Use `--mode volumes` (default) on the same helper — see [manual / final snapshots](./manual-snapshots.md).
3. **Already covered by AWS Backup / DLM?** Confirm recent successful recovery points before deleting compute.

### Create a final AMI

```shell
aws ec2 create-image \
  --instance-id <INSTANCE_ID> \
  --name "final-<INSTANCE_ID>-$(date +%Y%m%d)" \
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

## Related Scripts

- [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh) — instance-scoped JSON/CSV report generator (`--instance` required; `-f json|csv`)

## References

- [AWS CLI EC2 Reference](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- [Amazon EBS snapshots](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-snapshots.html)
- [AMI lifecycle](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMILifecycle.html)
- [Data Lifecycle Manager](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)
- [AWS Backup for EC2](https://docs.aws.amazon.com/aws-backup/latest/devguide/ec2-backup.html)
- [terminate-instances](https://docs.aws.amazon.com/cli/latest/reference/ec2/terminate-instances.html)
