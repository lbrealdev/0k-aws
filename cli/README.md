# AWS CLI

Universal Command Line Interface for Amazon Web Services.

This directory is a cheat-sheet index for day-to-day `aws` usage. **Convention:** each markdown file maps to an AWS CLI subcommand or service area (`configure` → `aws configure`, `ec2` → `aws ec2`, `s3` → `aws s3`, and so on). This README is the hub for install, setup pointers, and common nuances — not a subcommand page.

## Install AWS CLI v2

Prefer **AWS CLI v2**. v1 still exists on PyPI but is legacy; new setups should install v2.

Download the `awscliv2` package (Linux x86_64 example):

```shell
curl -fsSLo "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
```

Extract the installer:

```shell
unzip -q awscliv2.zip
```

Run the installer:

```shell
sudo ./aws/install
```

Confirm the version:

```shell
aws --version
```

For other platforms and updates, see the official [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

## First-time setup

After install, configure credentials and defaults, then authenticate the way your account expects:

- [configure](./configure.md) — `aws configure list`, import access-key CSV
- [login](./login.md) — `aws login` / `aws logout`
- [SSO](./sso.md) — SSO admin / Identity Center related commands
- [STS](./sts.md) — caller identity and temporary credentials
- Broader auth methods: [aws-auth/](../aws-auth/README.md)

## Everyday nuances

### Profiles

Use a named profile per account/role:

```shell
aws sts get-caller-identity --profile <profile>
```

Or export it for a shell session:

```shell
export AWS_PROFILE=<profile>
```

### Region

Many calls fail or hit the wrong place when region is unset. Set a default with `aws configure`, pass `--region`, or export `AWS_REGION` / `AWS_DEFAULT_REGION`.

### Output and `--query`

Default output is often JSON. Useful flags:

```shell
aws ec2 describe-instances --output table
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text
```

### Pager

AWS CLI v2 may send long output through a pager (like `less`). For scripts and clean capture, disable it:

```shell
aws ec2 describe-instances --no-cli-pager
```

Or set `AWS_PAGER=""` in the environment.

### Credential chain gotchas

The CLI resolves credentials from several sources (environment variables, shared config/credentials files, SSO cache, etc.). If identity looks “wrong”:

1. Check `aws sts get-caller-identity` (with and without `--profile`)
2. Inspect `aws configure list`
3. Confirm you are not mixing env vars (`AWS_ACCESS_KEY_ID`, …) with an intended SSO profile

## Pages in this section

| Page | CLI area |
|------|----------|
| [configure](./configure.md) | `aws configure` |
| [login](./login.md) | `aws login` / `aws logout` |
| [sso](./sso.md) | `aws sso` / `aws sso-admin` |
| [sts](./sts.md) | `aws sts` |
| [iam](./iam.md) | `aws iam` |
| [ec2](./ec2.md) | `aws ec2` |
| [ec2-ami](./ec2-ami.md) | EC2 AMIs |
| [ec2-snapshots](./ec2-snapshots.md) | EC2 snapshots |
| [security-groups](./security-groups.md) | Security groups |
| [securityhub](./securityhub.md) | `aws securityhub` |
| [vpc](./vpc.md) | `aws ec2` VPC-related |
| [eks](./eks.md) | `aws eks` |
| [s3](./s3.md) | `aws s3` / `aws s3api` |
| [secrets-manager](./secrets-manager.md) | `aws secretsmanager` |
| [opensearch](./opensearch.md) | `aws opensearch` |
| [codeartifact](./codeartifact.md) | `aws codeartifact` |
| [codebuild](./codebuild.md) | `aws codebuild` |
| [codecommit](./codecommit.md) | `aws codecommit` |
| [codedeploy](./codedeploy.md) | `aws codedeploy` |
| [codepipeline](./codepipeline.md) | `aws codepipeline` |

Also see the [root README](../README.md) TOC for the full wiki index.

## References

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/)
- [What is the AWS Command Line Interface?](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html)
- [Installing or updating the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [AWS CLI v2 on GitHub](https://github.com/aws/aws-cli)
- [Configuration and credential file settings](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)
- [Using AWS CLI pagination options](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-pagination.html)
