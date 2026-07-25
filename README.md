# 0k-aws

A personal wiki of AWS knowledge: CLI cheat sheets, operational guides, and helper scripts, collected from real-world usage.

## Sections

| Section | What's inside |
|---------|---------------|
| [auth/](./auth/README.md) | IAM users, AWS SSO, IAM Identity Center |
| [cli/](./cli/README.md) | AWS CLI v2 install, profile/region/pager nuances, one page per `aws` subcommand |
| [cloudshell/](./cloudshell/README.md) | Persistent tooling (mise, just) in the CloudShell environment |
| [ec2/](./ec2/README.md) | Inventory, manual/final snapshots, safe elimination |
| [rds/](./rds/README.md) | RDS deletion considerations and checklist |
| [list-resources/](./list-resources/README.md) | Account-wide discovery: AWS Config, Cloud Control API, CDK, Steampipe |
| [dev-tools/](./dev-tools/README.md) | CodeCommit, CodeBuild, CodePipeline, reporting scripts |
| [scripts/](./scripts/README.md) | Helper scripts, each marked read-only or write |

Each directory README is the index for its own pages; this file links to sections only.

## Prerequisites

- [AWS CLI v2](./cli/install.md) — install notes and first-time setup
- `jq` — required by several scripts
- [mise](https://mise.jdx.dev/) — optional; `mise.toml` pins Steampipe and provides `mise t` to list the tools installed for this directory

## Running the scripts

Write scripts are marked **write** in [scripts/README.md](./scripts/README.md) and support `--dry-run` where practical. Run them with `--dry-run` first, and pass an explicit `--profile` / `--region` rather than relying on shell defaults.

## Conventions

- Every directory has a `README.md` that indexes its pages.
- Each page under `cli/` maps to an `aws` subcommand or service area.
- Link lists use the form `[Page](./page.md)` followed by an em dash and a short description.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/), for example `docs(ec2):` or `feat(scripts):`.
