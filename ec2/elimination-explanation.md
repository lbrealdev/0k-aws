# Why EC2 elimination matters

Terminating EC2 instances is not the same as eliminating EC2 cost and risk. Volumes, snapshots, AMIs, Elastic IPs, ENIs, DLM policies, and AWS Backup recovery points can remain after instances are gone.

For the step-by-step procedure, see [Eliminate EC2 instances](./elimination.md).

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

## Snapshots vs AMIs vs AWS Backup vs DLM

These are related but not interchangeable:

- **EBS snapshot**: backup of a single volume. Fastest primitive for volume restore.
- **AMI**: package of instance configuration + one or more snapshots. Needed to relaunch an instance image cleanly.
- **DLM**: automation that creates/retains/deletes snapshots or AMIs on a schedule. Disabling/deleting instances does not remove the policy.
- **AWS Backup**: organization-friendly backup plans and vaults. Recovery points may appear as snapshots in EC2, but lifecycle is controlled by Backup (especially when vault lock / retention rules apply).

For elimination projects, inventory **all four**. Keeping only “EC2 console snapshots” is incomplete.

## Related

- [Eliminate EC2 instances](./elimination.md): inventory, backups, and termination checklist
- [AWS Backup recovery points](./backup-recovery-points.md): recovery-point filter reference
