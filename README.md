# 0k-aws

A personal wiki of AWS knowledge. CLI commands, practical tips, and lessons learned from real-world usage.

<!-- TOC -->

- [AWS Auth](#aws-auth)
  - [Overview](./aws-auth/README.md)
  - [IAM User](./aws-auth/iam-user.md)
  - [AWS SSO](./aws-auth/aws-sso.md)
  - [IAM Identity Center](./aws-auth/iam-identity-center.md)
- [CLI](#cli)
  - [Overview](./cli/README.md)
  - [Configure](./cli/configure.md)
  - [CodeArtifact](./cli/codeartifact.md)
  - [CodeBuild](./cli/codebuild.md)
  - [CodeCommit](./cli/codecommit.md)
  - [CodeDeploy](./cli/codedeploy.md)
  - [CodePipeline](./cli/codepipeline.md)
  - [EC2](./cli/ec2.md)
  - [EC2 AMI](./cli/ec2-ami.md)
  - [EC2 Snapshots](./cli/ec2-snapshots.md)
  - [Security Groups](./cli/security-groups.md)
  - [Security Hub](./cli/securityhub.md)
  - [Secrets Manager](./cli/secrets-manager.md)
  - [VPC](./cli/vpc.md)
  - [EKS](./cli/eks.md)
  - [IAM](./cli/iam.md)
  - [OpenSearch](./cli/opensearch.md)
  - [S3](./cli/s3.md)
  - [STS](./cli/sts.md)
  - [SSO](./cli/sso.md)
  - [Login](./cli/login.md)
- [AWS CloudShell](#aws-cloudshell)
  - [Overview](./aws-cloudshell/README.md)
- [Databases](#databases)
  - [Overview](./databases/README.md)
  - [RDS Deletion](./databases/rds-deletion.md)
- [EC2](#ec2)
  - [Overview](./ec2/README.md)
  - [EC2 Elimination](./ec2/ec2-elimination.md)
- [AWS List Resources](#aws-list-resources)
  - [Overview](./aws-list-resources/README.md)
  - [AWS Config](./aws-list-resources/aws-config.md)
  - [Cloud Control API](./aws-list-resources/aws-cloud-control-api.md)
  - [AWS CDK](./aws-list-resources/aws-cdk.md)
  - [Steampipe](./aws-list-resources/tools/steampipe.md)
- [AWS Developer Tools](#aws-developer-tools)
  - [Overview](./developer-tools/README.md)
  - [CodeCommit](./developer-tools/codecommit/README.md)
  - [CodeBuild](./developer-tools/codebuild/README.md)
  - [CodePipeline](./developer-tools/codepipeline/README.md)
- [Scripts](#scripts)
  - [ec2-inventory.sh](./scripts/ec2-inventory.sh)
  - [rds-modify-snapshot.sh](./scripts/rds-modify-snapshot.sh)
  - [s3-bucket-object.sh](./scripts/s3-bucket-object.sh)
  - [list-resources.sh](./scripts/list-resources.sh)

---

## AWS Auth

Methods for authenticating with AWS.

See [aws-auth/README.md](./aws-auth/README.md) for the section index.

- [IAM User](./aws-auth/iam-user.md) — long-term credentials.
- [AWS SSO](./aws-auth/aws-sso.md) — SSO / IAM Identity Center for multi-account access.
- [IAM Identity Center](./aws-auth/iam-identity-center.md) — Identity Center references and instance types.

---

## CLI

AWS CLI install notes, everyday nuances, and command cheat sheets. Each page under `cli/` maps to an `aws` subcommand or service area; see [cli/README.md](./cli/README.md) for the section hub.

---

## AWS CloudShell

Tooling tips for the AWS CloudShell environment.

See [aws-cloudshell/README.md](./aws-cloudshell/README.md) for the section index.

---

## Databases

Operational guides for AWS database services.

See [databases/README.md](./databases/README.md) for the section index.

- [RDS Deletion](./databases/rds-deletion.md) — considerations and checklist for deleting an RDS instance.

---

## EC2

Operational guides and good practices for day-to-day Amazon EC2 work — inventory, backups, and cleanup.

See [ec2/README.md](./ec2/README.md) for the section index.

- [EC2 Elimination](./ec2/ec2-elimination.md) — inventory volumes, snapshots, AMIs, DLM, and AWS Backup before removing EC2 resources.

---

## AWS List Resources

Approaches and tools for discovering resources across an AWS account.

See [aws-list-resources/README.md](./aws-list-resources/README.md) for the section index.

- [AWS Config](./aws-list-resources/aws-config.md) — inventory via AWS Config.
- [Cloud Control API](./aws-list-resources/aws-cloud-control-api.md) — list resources with Cloud Control.
- [AWS CDK](./aws-list-resources/aws-cdk.md) — CDK-related resource listing notes.
- [Steampipe](./aws-list-resources/tools/steampipe.md) — query AWS with Steampipe.

---

## AWS Developer Tools

AWS Developer Tools is a set of services designed to help developers build, test, deploy, and manage applications on AWS.

See [developer-tools/README.md](./developer-tools/README.md) for more details.

---

## Scripts

Helper scripts for common operational tasks.

- [`scripts/ec2-inventory.sh`](./scripts/ec2-inventory.sh) — read-only, instance-scoped inventory (volumes, snapshots, AMIs, DLM, Backup).
- [`scripts/rds-modify-snapshot.sh`](./scripts/rds-modify-snapshot.sh) — batch-modify RDS DB snapshot option groups.
- [`scripts/s3-bucket-object.sh`](./scripts/s3-bucket-object.sh) — list object counts per S3 bucket.
- [`scripts/list-resources.sh`](./scripts/list-resources.sh) — list account resources across profiles/regions.
