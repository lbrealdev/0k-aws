# AWS DevOps Agent

AWS DevOps Agent investigates incidents and operational issues across AWS
accounts and connected tools (observability, code, ticketing, chat).

## Concepts

- **Agent Space**: the unit of configuration. It holds the accounts,
  integrations, and permissions the agent can use. It lives in one account and
  region ([Supported Regions](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-supported-regions.html);
  the control plane is not available in every region).
- **Primary source** (`accountType: monitor`): the account that hosts the
  Agent Space. Associated with `serviceId aws` and the `aws` configuration key.
- **Secondary source** (`accountType: source`): any other account the agent
  investigates. Associated with `serviceId aws` and the `sourceAws`
  configuration key. The agent assumes a role in that account.

To create an Agent Space, see the [CLI onboarding
guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html).

## Add secondary sources to an existing Agent Space

Typical flow: the primary account already has DevOps Agent and an Agent Space.
Secondary sources are other accounts (often under an Organizations OU). For
each target account the helper script:

1. Creates or updates an IAM role that trusts `aidevops.amazonaws.com` with
   `aws:SourceAccount` = primary account and `aws:SourceArn` = Agent Space ARN,
   and attaches `AIDevOpsAgentAccessPolicy` (idempotent).
2. From the primary profile, calls `aws devops-agent associate-service` with
   `--service-id aws` and a `sourceAws` configuration (same pattern as the
   [CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html)).
3. Lists associations (`list-associations`) so you can confirm what the Agent
   Space holds after the run.

Access is **SSO profiles only**: `--profile` is the Agent Space owner; each
target uses its SSO profile (`sso_account_id` in `~/.aws/config`, same idea as
[`find-iam-role.sh`](../scripts/find-iam-role.sh)), or an explicit
`--target-profile ACCOUNT=PROFILE`. Accounts with no profile or not logged in
are skipped (same skip style as `find-iam-role.sh`).

### Prerequisites

**Primary account (caller / `--profile`):**

- Credentials for the Agent Space owner (SSO profile).
- Permission to call `aidevops:AssociateService` / `ListAssociations` (and
  Organizations APIs if using `--ou-id`).
- `iam:PassRole` on `arn:aws:iam::<PRIMARY_ACCOUNT_ID>:role/*` with
  `iam:PassedToService` = `aidevops.amazonaws.com`. Without this,
  `associate-service` for a secondary account fails with HTTP 403 naming
  `iam:PassRole`, even if the caller has `aidevops:*`. See [Connecting
  multiple AWS
  Accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-connecting-multiple-aws-accounts.html).

**Each secondary (target) account:**

- SSO profile logged in (or mapped via `--target-profile`).
- Permission to `iam:CreateRole`, `iam:UpdateAssumeRolePolicy`,
  `iam:AttachRolePolicy`, and `iam:GetRole` / `iam:ListAttachedRolePolicies`
  for the role name you pass.
- The role trusts `aidevops.amazonaws.com` with `aws:SourceAccount` /
  `aws:SourceArn` conditions and has `AIDevOpsAgentAccessPolicy` attached
  (the script ensures this).

### Multi-account / overwrite (untested)

The [associate-service
reference](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/associate-service.html)
says the call “overwrites the existing association of the same service.” The
official onboarding examples still use `--service-id aws` for every secondary
`sourceAws` association. This repo has **not** verified whether repeated
`associate-service` calls with `serviceId aws` retain multiple secondary
accounts or replace prior `sourceAws` rows.

**Acceptance criterion:** in a sandbox, associate two secondary accounts, run
`aws devops-agent list-associations --agent-space-id …`, and confirm both
accounts appear. The script prints `list-associations` after associates (and
prints that command under `--dry-run`).

`sourceAws` also accepts an optional `externalId` (`--external-id`).

### Manual CLI (reference)

Trust policy in the secondary account (replace placeholders):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "aidevops.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "<PRIMARY_ACCOUNT_ID>" },
      "ArnLike": {
        "aws:SourceArn": "arn:aws:aidevops:<REGION>:<PRIMARY_ACCOUNT_ID>:agentspace/<AGENT_SPACE_ID>"
      }
    }
  }]
}
```

```bash
# In the secondary account
aws iam create-role --role-name DevOpsAgentCrossAccountRole \
  --assume-role-policy-document file://trust.json --profile <SECONDARY_SSO>
aws iam attach-role-policy --role-name DevOpsAgentCrossAccountRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy \
  --profile <SECONDARY_SSO>

# In the primary account
aws devops-agent associate-service \
  --agent-space-id <AGENT_SPACE_ID> \
  --service-id aws \
  --configuration '{"sourceAws":{"accountId":"<ACCOUNT_ID>","accountType":"source","assumableRoleArn":"arn:aws:iam::<ACCOUNT_ID>:role/DevOpsAgentCrossAccountRole"}}' \
  --profile <PRIMARY_SSO> --region <REGION>

aws devops-agent list-associations \
  --agent-space-id <AGENT_SPACE_ID> \
  --profile <PRIMARY_SSO> --region <REGION>
```

The console may also attach an Agent Space–specific inline policy; this repo’s
script only ensures trust + `AIDevOpsAgentAccessPolicy`.

### Script

[`scripts/devops-agent-add-source.py`](../scripts/devops-agent-add-source.py) is
a [uv inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies)
(Python + boto3). Prefer it over a shell script: trust-policy JSON and
idempotent IAM are simpler in Python.

Required inputs match `associate-service`: `--agent-space-id`, a role ARN per
account via `--role-name` (default `DevOpsAgentCrossAccountRole`), optional
`--external-id`, plus `--profile` / `--region`.

```bash
# Preview: explicit accounts
./scripts/devops-agent-add-source.py --agent-space-id <AGENT_SPACE_ID> \
  --role-name DevOpsAgentCrossAccountRole \
  --profile <PRIMARY_SSO> --region <REGION> \
  --dry-run <ACCOUNT_ID> [<ACCOUNT_ID>...]

# Preview: ACTIVE accounts under an OU (skips already associated)
./scripts/devops-agent-add-source.py --agent-space-id <AGENT_SPACE_ID> \
  --profile <PRIMARY_SSO> --region <REGION> \
  --ou-id <OU_ID> --dry-run

# Optional explicit map when sso_account_id is missing or ambiguous
./scripts/devops-agent-add-source.py --agent-space-id <AGENT_SPACE_ID> \
  --profile <PRIMARY_SSO> --region <REGION> \
  --target-profile 111122223333=my-sso-profile --dry-run 111122223333

# Apply: drop --dry-run
```

`--dry-run` still uses SSO to decide create vs update, but only prints the
`iam create-role` / `update-assume-role-policy` / `attach-role-policy`,
`devops-agent associate-service`, and final `list-associations` commands.

Output (apply): one `ACCOUNT<TAB>ASSOCIATION_ID<TAB>STATUS` line per associate,
then association rows from `list-associations`. Exit codes: `0` success/help,
`1` usage, `2` AWS error ([AGENTS.md](../AGENTS.md)). Named `--profile` only
(env access keys refused). Requires [`uv`](https://docs.astral.sh/uv/).
Works on Linux and Git Bash (`\r` stripped when reading `~/.aws/config`).

## References

- [Connecting multiple AWS Accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-connecting-multiple-aws-accounts.html)
- [Supported Regions](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-supported-regions.html)
- [CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html)
- [`aws devops-agent associate-service`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/associate-service.html)
- [`aws devops-agent list-associations`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/list-associations.html)
- [`aws iam create-role`](https://docs.aws.amazon.com/cli/latest/reference/iam/create-role.html) /
  [`update-assume-role-policy`](https://docs.aws.amazon.com/cli/latest/reference/iam/update-assume-role-policy.html) /
  [`attach-role-policy`](https://docs.aws.amazon.com/cli/latest/reference/iam/attach-role-policy.html)
- [`aws organizations list-accounts-for-parent`](https://docs.aws.amazon.com/cli/latest/reference/organizations/list-accounts-for-parent.html)
- [boto3 `associate_service`](https://docs.aws.amazon.com/boto3/latest/reference/services/devops-agent/client/associate_service.html)
- [SourceAwsConfiguration (PassRole note)](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_SourceAwsConfiguration.html)
- [CloudFormation setup](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-getting-started-with-aws-devops-agent-using-aws-cloudformation.html)
