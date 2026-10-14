# Secondary sources

Associate **target** AWS accounts as secondary sources on an existing setup
in a **source** account.

## Concepts

- **Source account**: owns the setup; used with `--source-profile`.
- **Target account**: an organization account you add as a secondary source;
  used with `--target-profile` (account ID comes from STS).

Create the setup with the vendor CLI onboarding guide (see References). This
repo’s helper only associates additional target accounts.

## SSO profiles

Use named SSO profiles. The script calls `boto3.Session(profile_name=…)` and
resolves the account ID only with `sts:GetCallerIdentity` (no config scan).

Modern `~/.aws/config` shape (generic example):

```ini
[sso-session my-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile source-acct]
sso_session = my-sso
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = us-east-1

[profile target-acct]
sso_session = my-sso
sso_account_id = 444455556666
sso_role_name = AdministratorAccess
region = us-east-1
```

Log in before running:

```bash
aws sso login --profile source-acct
aws sso login --profile target-acct
```

If the SSO token is missing or expired, the script fails and tells you to run
`aws sso login --profile NAME`.

## Prerequisites

**Source account (`--source-profile`):**

- SSO login for the profile that owns the setup.
- Permission to call associate-service / list-associations.
- `iam:PassRole` on `arn:aws:iam::<SOURCE_ACCOUNT_ID>:role/*` (the **caller’s**
  account role wildcard — not the target role ARN) with
  `iam:PassedToService` = `aidevops.amazonaws.com`. The check runs on the
  source caller even though the role ARN points at the target account;
  policies scoped to individual role ARNs do not satisfy it. See
  [Connecting multiple AWS
  Accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-connecting-multiple-aws-accounts.html)
  and
  [SourceAwsConfiguration](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_SourceAwsConfiguration.html).

**Each target account (`--target-profile`):**

- SSO login for that profile.
- An IAM role that already exists with:
  - trust for service principal `aidevops.amazonaws.com` with
    `aws:SourceAccount` = source account and `aws:SourceArn` = setup ARN;
  - managed policy `AIDevOpsAgentAccessPolicy` attached.
- The script **verifies** these; it does **not** create or modify IAM. Fix
  gaps in the target account first, then re-run.

`--ou-id` is not supported: listing OU members cannot map to SSO profiles
without scanning `~/.aws/config`. Pass one `--target-profile` per target.

## Manual role setup (target account)

Trust policy (replace placeholders):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "aidevops.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "<SOURCE_ACCOUNT_ID>" },
      "ArnLike": {
        "aws:SourceArn": "arn:aws:aidevops:<REGION>:<SOURCE_ACCOUNT_ID>:agentspace/<SETUP_ID>"
      }
    }
  }]
}
```

```bash
aws iam create-role --role-name DevOpsAgentCrossAccountRole \
  --assume-role-policy-document file://trust.json --profile <TARGET_SSO>
aws iam attach-role-policy --role-name DevOpsAgentCrossAccountRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy \
  --profile <TARGET_SSO>
```

## Script

[`scripts/add-secondary-source.py`](../scripts/add-secondary-source.py) is a
[uv inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies)
(Python + boto3).

**Usual flags:** `--setup-id`, `--source-profile`, `--region`, one or more
`--target-profile`, optional `--dry-run`, optional `-q` / `--quiet`.

**Advanced** (accepted; pointed from `--help`):

| Flag | Purpose |
|------|---------|
| `--role-name NAME` | IAM role name in each target (default `DevOpsAgentCrossAccountRole`) |
| `--external-id ID` | Optional `externalId` on the association |

```bash
# Preview
./scripts/add-secondary-source.py --setup-id <SETUP_ID> \
  --source-profile <SOURCE_SSO> --region <REGION> \
  --target-profile <TARGET_SSO> --dry-run

# Two targets
./scripts/add-secondary-source.py --setup-id <SETUP_ID> \
  --source-profile <SOURCE_SSO> --region <REGION> \
  --target-profile <TARGET_A> --target-profile <TARGET_B>

# Apply: drop --dry-run
```

### Output

- **stderr:** one-line header, then `[ok]` / `[warn]` / `[fail]` / `[skip]` /
  `[dry-run]` status rows, then a `summary` with
  `associated` / `skipped` / `failed` counts. Color only when stderr is a TTY
  and `NO_COLOR` is unset. Profile names and other interpolated values are
  escaped for safe terminal rendering.
- **stdout:** machine-useful rows only (association `ACCOUNT_ID`, id, status;
  under `--dry-run`, the planned CLI commands).
- `-q` / `--quiet`: hide header and non-error status on stderr; errors still
  print.

### Flow and safeguards

One run: verify each target role → associate → retention check (fail if a
prior associated account disappears; poll briefly for the new one) → final
list. Missing `iam:PassRole` fails immediately (no long retry). `--dry-run`
prints associate/list commands on stdout and writes nothing (SSO still needed
for STS and IAM reads).

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage (bad args / unknown flags / env credentials set) |
| 2 | Verification, precondition, or AWS failure |

Requires [`uv`](https://docs.astral.sh/uv/).

## Multi-account caveat

The associate-service reference says the call overwrites the existing
association of the same service. Vendor onboarding still uses one call per
target. Until proven in a sandbox, the script fails loudly if a previously
associated account disappears after an associate.

## References

- [Connecting multiple AWS Accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-connecting-multiple-aws-accounts.html)
- [CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html)
- [`associate-service`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/associate-service.html)
- [`list-associations`](https://docs.aws.amazon.com/cli/latest/reference/devops-agent/list-associations.html)
- [SourceAwsConfiguration](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_SourceAwsConfiguration.html)
