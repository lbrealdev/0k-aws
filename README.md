# 0k-aws

A personal wiki of AWS knowledge: CLI cheat sheets, operational guides, and helper scripts, collected from real-world usage.

| Section | What's inside |
|---------|---------------|
| [auth/](./auth/README.md) | IAM users, AWS SSO, IAM Identity Center |
| [cli/](./cli/README.md) | AWS CLI v2 install, profile/region/pager nuances, one page per `aws` subcommand |
| [cloudshell/](./cloudshell/README.md) | Persistent tooling (mise, just) in the CloudShell environment |
| [cloudwatch/](./cloudwatch/README.md) | Billing alarm analysis and CloudWatch helpers |
| [ec2/](./ec2/README.md) | Inventory, manual/final snapshots, safe elimination, Windows patch-state checks |
| [rds/](./rds/README.md) | RDS deletion considerations and checklist |
| [list-resources/](./list-resources/README.md) | Account-wide discovery: AWS Config, Cloud Control API, CDK, Steampipe |
| [dev-tools/](./dev-tools/README.md) | CodeCommit, CodeBuild, CodePipeline, reporting scripts |
| [scripts/](./scripts/README.md) | Helper scripts, each marked read-only or write |

## Running the scripts

Write scripts are marked **write** in [scripts/README.md](./scripts/README.md) and support `--dry-run` where practical. Run them with `--dry-run` first, and pass an explicit `--profile` / `--region` rather than relying on shell defaults.
