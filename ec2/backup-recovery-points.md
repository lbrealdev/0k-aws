# AWS Backup recovery points (reference)

Lookup-only reference for inspecting AWS Backup recovery points for EC2/EBS. For the elimination procedure, see [Eliminate EC2 instances](./elimination.md).

## Investigate recovery points (before adding a Backup filter)

Do **not** assume a tag-based Backup filter will help. Start with what `list-recovery-points-by-backup-vault` actually returns.

Important: that API does **not** include a `Tags` attribute on recovery points. See the [API reference](https://docs.aws.amazon.com/aws-backup/latest/APIReference/API_ListRecoveryPointsByBackupVault.html) and [CLI reference](https://docs.aws.amazon.com/cli/latest/reference/backup/list-recovery-points-by-backup-vault.html). Useful server-side filters include `--by-resource-arn`, `--by-resource-type`, and `--by-backup-plan-id`.

### 1. List vaults

```shell
aws backup list-backup-vaults \
  --query 'BackupVaultList[].BackupVaultName' \
  --output table
```

### 2. Inspect recovery points in one vault

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

### 3. Focus on EC2 / EBS recovery points

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

### 4. Optional: inspect tags on a single recovery point

Tags are not returned by `list-recovery-points-by-backup-vault`. Fetch them per recovery point with `list-tags`:

```shell
aws backup list-tags \
  --resource-arn <RECOVERY_POINT_ARN> \
  --output json
```

Repeat for a sample of EC2/EBS recovery points and look for a common key/value. Only if that pattern is stable is a future tag-based filter worth considering.

## Decision rule

| Finding | Action |
|---------|--------|
| Recovery points are easy to target by resource ARN / resource type / backup plan ID | Prefer those filters; no tag flag needed |
| `list-tags` shows a common key + stable value on recovery points | A tag-based filter flag may be worth adding later |
| Tags empty, inconsistent, or only on the source instance/volume | Do not add a tag filter; prefer ARN-based discovery |

Script default path:

1. [`scripts/ec2-inventory.sh`](../scripts/ec2-inventory.sh) uses `list-recovery-points-by-resource` for the instance ARN and each volume ARN (fast, no vault scan, no tag assumptions)
2. Optional later: a tag-based approach **only if** step 4 confirms a useful recovery-point tag

Manual vault inspection above remains useful for exploration; it is not how the helper discovers recovery points.
