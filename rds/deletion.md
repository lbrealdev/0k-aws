# Delete an RDS instance

Deleting an RDS instance is permanent. Once deleted, the instance and its automated backups are gone unless you keep a manual snapshot. This how-to covers deleting a manually-created RDS instance.

## Pre-deletion checklist

- Check for read replicas. They must be deleted before the primary instance, and both deletions require `--skip-final-snapshot`:
  ```shell
  aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
    --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers'
  ```
- Disable deletion protection if enabled:
  ```shell
  # Check
  aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
    --query 'DBInstances[0].DeletionProtection'

  # Disable
  aws rds modify-db-instance --db-instance-identifier <INSTANCE_ID> \
    --no-deletion-protection --apply-immediately
  ```
- Check whether the instance is in a failure state (`failed`, `incompatible-restore`, or `incompatible-network`). Failure states can only be deleted with `--skip-final-snapshot`:
  ```shell
  aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
    --query 'DBInstances[0].DBInstanceStatus'
  ```

## Snapshots

### Manual vs automated snapshots

- **Automated snapshots** are taken automatically by RDS on a schedule. They are deleted when the instance is deleted.
- **Manual snapshots** are created explicitly. They persist after the instance is deleted.

When you delete an instance, RDS creates a final manual snapshot by default. You must explicitly pass `--skip-final-snapshot` to skip it. In production, always keep the default behavior (don't skip it).

### Review existing snapshots

List all snapshots for the instance:
```shell
aws rds describe-db-snapshots --db-instance-identifier <INSTANCE_ID> \
  --query 'DBSnapshots[*].[DBSnapshotIdentifier,SnapshotType,Status,SnapshotCreateTime]' \
  --output table
```

Filter by snapshot type:
```shell
# Manual snapshots only
aws rds describe-db-snapshots --db-instance-identifier <INSTANCE_ID> \
  --snapshot-type manual \
  --query 'DBSnapshots[*].[DBSnapshotIdentifier,Status,SnapshotCreateTime]' \
  --output table

# Automated snapshots only
aws rds describe-db-snapshots --db-instance-identifier <INSTANCE_ID> \
  --snapshot-type automated \
  --query 'DBSnapshots[*].[DBSnapshotIdentifier,Status,SnapshotCreateTime]' \
  --output table
```

### Create a final snapshot

```shell
aws rds create-db-snapshot \
  --db-instance-identifier <INSTANCE_ID> \
  --db-snapshot-identifier <SNAPSHOT_NAME>
```

Wait for the snapshot to be available before deleting the instance:
```shell
aws rds wait db-snapshot-available --db-snapshot-identifier <SNAPSHOT_NAME>
```

### Snapshot retention

Manual snapshots persist indefinitely and incur storage costs. Set a reminder to delete them when no longer needed:
```shell
aws rds delete-db-snapshot --db-snapshot-identifier <SNAPSHOT_NAME>
```

## Delete the instance

With a final snapshot (default):
```shell
aws rds delete-db-instance \
  --db-instance-identifier <INSTANCE_ID> \
  --final-db-snapshot-identifier <SNAPSHOT_NAME> \
  --delete-automated-backups
```

Without a final snapshot (only for failure states, read replicas, or RDS Custom):
```shell
aws rds delete-db-instance \
  --db-instance-identifier <INSTANCE_ID> \
  --skip-final-snapshot \
  --delete-automated-backups
```

Multi-AZ instances remove both the primary and standby when deleted.

## After you delete

1. Confirm the final snapshot exists before treating the deletion as done:
```shell
aws rds describe-db-snapshots --db-snapshot-identifier <SNAPSHOT_NAME> \
  --query 'DBSnapshots[0].[DBSnapshotIdentifier,Status]' \
  --output table
```
2. Delete associated resources that are not removed automatically: subnet groups, parameter groups, and security groups.
3. Check CloudWatch logs and metrics for the instance. They persist and continue to incur costs until removed.
4. For RDS Custom instances, the underlying EC2 instance and its EBS volumes are deleted permanently with the RDS instance. Do not terminate or delete those resources yourself first.
5. Review manual snapshot storage costs periodically to avoid charges from forgotten snapshots.

## Related scripts

- [`scripts/rds-modify-snapshot.sh`](../scripts/rds-modify-snapshot.sh) — batch-modify RDS DB snapshot option groups (`awsbackup` or `manual` snapshots).
- [`scripts/rds-snapshot-age.sh`](../scripts/rds-snapshot-age.sh) — read-only age report before cleaning leftover manuals.

## References

- [AWS CLI RDS Reference](https://docs.aws.amazon.com/cli/latest/reference/rds/)
- [delete-db-instance](https://docs.aws.amazon.com/cli/latest/reference/rds/delete-db-instance.html)
- [Deleting a DB Instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DeleteInstance.html)
