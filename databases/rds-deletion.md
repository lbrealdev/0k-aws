# RDS Instance Deletion

Deleting an RDS instance is a permanent action. Once deleted, the instance and its automated backups are gone. This document covers the considerations you should take before proceeding with the deletion of an RDS instance.

## Pre-Deletion Checklist

Verify the instance is not in use by checking active connections and application configurations:
```shell
aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
  --query 'DBInstances[0].DBInstanceStatus'
```

Check if the instance is managed by infrastructure-as-code (CloudFormation, Terraform, CDK). If so, delete it through the IaC tool instead of manually:
```shell
# CloudFormation
aws cloudformation list-stack-resources --stack-name <STACK_NAME>

# Terraform
terraform state list | grep rds
```

Check for read replicas. These must be deleted before the primary instance. Note that read replicas require `--skip-final-snapshot` when deleting:
```shell
aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
  --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers'
```

Check if deletion protection is enabled and disable it if needed:
```shell
# Check
aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
  --query 'DBInstances[0].DeletionProtection'

# Disable
aws rds modify-db-instance --db-instance-identifier <INSTANCE_ID> \
  --no-deletion-protection --apply-immediately
```

Confirm the instance was not created from a snapshot (useful to know for rollback purposes):
```shell
aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
  --query 'DBInstances[0].SnapshotIdentifier'
```

Check if the instance is in a failure state. Instances with status `failed`, `incompatible-restore`, or `incompatible-network` can only be deleted with `--skip-final-snapshot` (no final snapshot will be created):
```shell
aws rds describe-db-instances --db-instance-identifier <INSTANCE_ID> \
  --query 'DBInstances[0].DBInstanceStatus'
```

Verify there are no dependent resources such as applications, Lambda functions, CloudWatch alarms, or DNS records pointing to the instance endpoint.

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

## Other Important Observations

- **Deletion is irreversible.** Unless you have a snapshot to restore from, the data is gone.
- **Associated resources are not automatically deleted.** Subnet groups, parameter groups, and security groups must be cleaned up separately.
- **CloudWatch logs and metrics are not deleted with the instance.** These persist and continue to incur costs if not addressed.
- **Multi-AZ instances** remove both the primary and standby when deleted.
- **Consider stopping the instance first** to save on compute costs without committing to full deletion. A stopped instance can be restarted within 7 days (after that, it is automatically started by RDS).
  ```shell
  aws rds stop-db-instance --db-instance-identifier <INSTANCE_ID>
  ```
- **Review manual snapshot storage costs** periodically to avoid unexpected charges from forgotten snapshots.
- **RDS Custom instances** — deleting an RDS Custom instance permanently deletes the underlying EC2 instance and associated EBS volumes. Do not terminate or delete these resources separately before deleting the RDS instance, as it may cause the deletion and final snapshot creation to fail. Read replicas and RDS Custom instances require `--skip-final-snapshot`.
