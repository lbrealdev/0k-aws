# RDS Instance Deletion

Deleting an RDS instance is a permanent action. Once deleted, the instance and its automated backups are gone. This document covers the considerations you should take before proceeding with the deletion of a manually-created RDS instance.

## Pre-Deletion Checklist

- Check for read replicas — these must be deleted before the primary instance and require `--skip-final-snapshot`
- Disable deletion protection if enabled
- Check if the instance is in a failure state (`failed`, `incompatible-restore`, or `incompatible-network`) — can only delete with `--skip-final-snapshot`

## Snapshots

### Manual vs Automated Snapshots

- **Automated snapshots** are taken automatically by RDS on a schedule. They are deleted when the instance is deleted.
- **Manual snapshots** are created explicitly. They persist after the instance is deleted.

When you delete an instance, RDS creates a final manual snapshot by default. You must explicitly pass `--skip-final-snapshot` to skip it. In production, always keep the default behavior (don't skip it).

### Review Existing Snapshots

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

### Create a Final Snapshot

```shell
aws rds create-db-snapshot \
  --db-instance-identifier <INSTANCE_ID> \
  --db-snapshot-identifier <SNAPSHOT_NAME>
```

Wait for the snapshot to be available before deleting the instance:
```shell
aws rds wait db-snapshot-available --db-snapshot-identifier <SNAPSHOT_NAME>
```

### Snapshot Retention

Manual snapshots persist indefinitely and incur storage costs. Set a reminder to delete them when no longer needed:
```shell
aws rds delete-db-snapshot --db-snapshot-identifier <SNAPSHOT_NAME>
```

## Deletion

With a final snapshot (default):
```shell
aws rds delete-db-instance \
  --db-instance-identifier <INSTANCE_ID> \
  --final-db-snapshot-identifier <SNAPSHOT_NAME> \
  --delete-automated-backups
```

Without a final snapshot (only for failure states or read replicas):
```shell
aws rds delete-db-instance \
  --db-instance-identifier <INSTANCE_ID> \
  --skip-final-snapshot \
  --delete-automated-backups
```

## Other Important Observations

- **Deletion is irreversible.** Unless you have a snapshot to restore from, the data is gone.
- **Associated resources are not automatically deleted.** Subnet groups, parameter groups, and security groups must be cleaned up separately.
- **CloudWatch logs and metrics are not deleted with the instance.** These persist and continue to incur costs if not addressed.
- **Multi-AZ instances** remove both the primary and standby when deleted.
- **Review manual snapshot storage costs** periodically to avoid unexpected charges from forgotten snapshots.
- **RDS Custom instances** — deleting an RDS Custom instance permanently deletes the underlying EC2 instance and associated EBS volumes. Do not terminate or delete these resources separately before deleting the RDS instance, as it may cause the deletion and final snapshot creation to fail. Read replicas and RDS Custom instances require `--skip-final-snapshot`.

## References

- [AWS CLI RDS Reference](https://docs.aws.amazon.com/cli/latest/reference/rds/)
- [delete-db-instance](https://docs.aws.amazon.com/cli/latest/reference/rds/delete-db-instance.html)
- [Deleting a DB Instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DeleteInstance.html)
