# Manual / final EC2 snapshots

Intentional EBS snapshots before a destructive or hard-to-reverse EC2 change — decommission, volume replace, migration, or a risky config change. This is a day-to-day ops practice; elimination is one consumer of it.

For a full teardown checklist, see [EC2 Elimination](./ec2-elimination.md).

## When to take them

- Before terminating or replacing an instance
- Before detaching / replacing a data volume
- Before a major OS or application change where rollback matters
- When AWS Backup / DLM coverage is unclear or not recent enough

Prefer stopping the instance first when downtime is acceptable (cleaner consistency). Snapshots of a **running** instance are still valid but crash-consistent (like power loss).

## Snapshot vs AMI

| Need | Use |
|------|-----|
| Restore disks / keep data | **EBS snapshot** (this practice) |
| Relaunch the same instance shape later | **AMI** (`create-image`) — see [Final backup procedure](./ec2-elimination.md#final-backup-procedure) |

## Tagging model

The helper uses `aws ec2 create-snapshots` with:

| Source | What |
|--------|------|
| Volume | All existing volume tags (`--copy-tags-from-source volume`) |
| Script default | `Purpose=manual-final-snapshot` only |
| Optional | Repeatable `--tag Key=Value` (ticket, reason, …) |

**Not** set by the script: `Name` (would overwrite copied volume names across the set) or `CreatedBy=<script-name>`.

Instance correlation belongs in the snapshot **description** and the JSON report.

## Retention

Manual snapshots persist and incur storage cost until you delete them. Set a reminder to remove them after restore confidence is high.

## Helper script

```shell
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --region <REGION> --dry-run
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --profile <PROFILE> --tag ChangeTicket=CHG123
./scripts/ec2-final-snapshot.sh -i i-aaa -i i-bbb --wait --yes
```

Requires a **live** instance (attached volumes). Does not terminate or delete anything. See [`scripts/ec2-final-snapshot.sh`](../scripts/ec2-final-snapshot.sh) and [`scripts/README.md`](../scripts/README.md).

Pair with read-only inventory first:

```shell
./scripts/ec2-inventory.sh -i <INSTANCE_ID> --region <REGION>
```

## Manual CLI (single volume)

If you only need one volume:

```shell
aws ec2 create-snapshot \
  --volume-id <VOLUME_ID> \
  --description "Manual final snapshot for <INSTANCE_ID>" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=manual-final-snapshot}]'
```

For multi-volume crash-consistent sets with tag copy, prefer the helper (or `aws ec2 create-snapshots` directly). More CLI notes: [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md).
