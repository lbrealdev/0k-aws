# AWS DevOps Agent

AWS DevOps Agent investigates incidents and operational issues across AWS
accounts and connected tools (observability, code, ticketing, chat).

## Concepts

- **Agent Space**: the unit of configuration. It holds the accounts,
  integrations, and permissions the agent can use. It lives in one account and
  region.
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
2. From the primary profile, calls `aws devops-agent associate-service` to add
   the account as a `sourceAws` source.

Access is **SSO profiles only**: `--profile` is the Agent Space owner; each
target uses its SSO profile (`sso_account_id` in `~/.aws/config`, same idea as
[`find-iam-role.sh`](../scripts/find-iam-role.sh)), or an explicit
`--target-profile ACCOUNT=PROFILE`. Accounts with no profile or not logged in
are skipped.

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
```

`associate-service` overwrites the existing association of the same service.
Verify multi-account behavior in a sandbox before relying on repeated
`associate-service` calls for several secondary sources. `sourceAws` also
accepts an optional `externalId`.

List Agent Spaces with `aws devops-agent list-agent-spaces`. List associations
with `aws devops-agent list-associations --agent-space-id ID`.

The console may also attach an Agent Space–specific inline policy; this repo’s
script only ensures trust + `AIDevOpsAgentAccessPolicy`.

### Script

[`scripts/devops-agent-add-source.py`](../scripts/devops-agent-add-source.py) is
a [uv inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies)
(Python + boto3). Prefer it over a shell script: trust-policy JSON and
idempotent IAM are simpler in Python.

```bash
# Preview: explicit accounts
./scripts/devops-agent-add-source.py --space-id <AGENT_SPACE_ID> \
  --role-name DevOpsAgentCrossAccountRole \
  --profile <PRIMARY_SSO> --region <REGION> \
  --dry-run <ACCOUNT_ID> [<ACCOUNT_ID>...]

# Preview: ACTIVE accounts under an OU (skips already associated)
./scripts/devops-agent-add-source.py --space-id <AGENT_SPACE_ID> \
  --profile <PRIMARY_SSO> --region <REGION> \
  --ou-id <OU_ID> --dry-run

# Optional explicit map when sso_account_id is missing or ambiguous
./scripts/devops-agent-add-source.py --space-id <AGENT_SPACE_ID> \
  --profile <PRIMARY_SSO> --region <REGION> \
  --target-profile 111122223333=my-sso-profile --dry-run 111122223333

# Apply: drop --dry-run
```

`--dry-run` still uses SSO to decide create vs update, but only prints the
`iam create-role` / `update-assume-role-policy` / `attach-role-policy` and
`devops-agent associate-service` commands.

Output (apply): one `ACCOUNT<TAB>ASSOCIATION_ID<TAB>STATUS` line per account.
Exit codes: `0` success, `2` usage or AWS error. Requires [`uv`](https://docs.astral.sh/uv/).
Works on Linux and Git Bash (`\r` stripped when reading `~/.aws/config`).

## References

- [Connecting multiple AWS accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-capabilities-for-aws-devops-agent-connecting-multiple-aws-accounts.html)
- [CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html)
- [`aws devops-agent associate-service`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/associate-service.html)
- [`aws devops-agent list-associations`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/list-associations.html)
- [`aws iam create-role`](https://docs.aws.amazon.com/cli/latest/reference/iam/create-role.html) /
  [`update-assume-role-policy`](https://docs.aws.amazon.com/cli/latest/reference/iam/update-assume-role-policy.html) /
  [`attach-role-policy`](https://docs.aws.amazon.com/cli/latest/reference/iam/attach-role-policy.html)
- [`aws organizations list-accounts-for-parent`](https://docs.aws.amazon.com/cli/latest/reference/organizations/list-accounts-for-parent.html)
- [boto3 `associate_service`](https://docs.aws.amazon.com/boto3/latest/reference/services/devops-agent/client/associate_service.html)
- [CloudFormation setup](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-getting-started-with-aws-devops-agent-using-aws-cloudformation.html)
