# Manual / final EC2 snapshots

Intentional backups before a destructive or hard-to-reverse EC2 change — decommission, volume replace, migration, or a risky config change. This is a day-to-day ops practice; elimination is one consumer of it.

For a full teardown checklist, see [EC2 Elimination](./ec2-elimination.md).

## When to take them

- Before terminating or replacing an instance
- Before detaching / replacing a data volume
- Before a major OS or application change where rollback matters
- When AWS Backup / DLM coverage is unclear or not recent enough

## Snapshot vs AMI

| Need | Use | Helper mode |
|------|-----|-------------|
| Restore disks / keep data | **EBS snapshots** | `--mode volumes` (default) |
| Relaunch the same instance shape later | **AMI** (`create-image`) | `--mode ami` |

## Consistency

- **Volumes mode:** crash-consistent multi-volume set (`create-snapshots`). Prefer stopping first when downtime is OK.
- **AMI mode (default):** for a **running** instance, AWS **reboots** during `create-image` so buffered data is flushed (safer). A stopped instance stays stopped.
- **AMI `--no-reboot`:** crash-consistent AMI; filesystem integrity is not guaranteed — use only when reboot is unacceptable.

## Tagging model

| Mode | Copied from volumes? | Script default | Optional |
|------|----------------------|----------------|----------|
| `volumes` | Yes (`--copy-tags-from-source volume`) | `Purpose=manual-final-snapshot` | `--tag Key=Value` |
| `ami` | No (AMI API limitation) | Same `Purpose` on AMI **and** all backing snapshots | `--tag Key=Value` on AMI + all backing snapshots |

**Not** set by the script as a tag: `Name` or `CreatedBy=<script-name>`.

In AMI mode the script generates the required `create-image --name` value internally (e.g. `final-<instance-id>-<timestamp>`). That is the AMI Name field, not a `Name` tag, and there is no user `--name` flag.

Instance correlation belongs in the description and the JSON report.

## Retention

Manual snapshots and AMIs persist and incur storage cost until you delete them. Deregistering an AMI does **not** delete its backing snapshots. Set a reminder to clean up after restore confidence is high.

## Helper script

```shell
# Volume snapshots (default)
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --region <REGION> --dry-run
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --tag ChangeTicket=CHG123

# AMI (reboots running instances by default)
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --mode ami --wait --yes
./scripts/ec2-final-snapshot.sh -i <INSTANCE_ID> --mode ami --no-reboot --dry-run
```

Requires a **live** instance (attached volumes). Does not terminate or delete anything. See [`scripts/ec2-final-snapshot.sh`](../scripts/ec2-final-snapshot.sh) and [`scripts/README.md`](../scripts/README.md).

Pair with read-only inventory first:

```shell
./scripts/ec2-inventory.sh -i <INSTANCE_ID> --region <REGION>
```

## Manual CLI

Single volume:

```shell
aws ec2 create-snapshot \
  --volume-id <VOLUME_ID> \
  --description "Manual final snapshot for <INSTANCE_ID>" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=manual-final-snapshot}]'
```

AMI (AWS reboots a running instance unless `--no-reboot`):

```shell
aws ec2 create-image \
  --instance-id <INSTANCE_ID> \
  --name "final-<INSTANCE_ID>-$(date -u +%Y%m%dT%H%M%SZ)" \
  --description "Manual final AMI for <INSTANCE_ID>" \
  --tag-specifications \
    'ResourceType=image,Tags=[{Key=Purpose,Value=manual-final-snapshot}]' \
    'ResourceType=snapshot,Tags=[{Key=Purpose,Value=manual-final-snapshot}]'
```

Prefer the helper for multi-volume sets, tag copy (volumes mode), and consistent reporting. More CLI notes: [`cli/ec2-snapshots.md`](../cli/ec2-snapshots.md), [`cli/ec2-ami.md`](../cli/ec2-ami.md).
