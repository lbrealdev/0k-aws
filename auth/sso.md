# AWS SSO

AWS Single Sign-On (SSO) / IAM Identity Center is the recommended way to authenticate to AWS for organizations with multiple accounts.

SSO provides centralized authentication and authorization across AWS accounts in AWS Organizations.

## Prerequisites

- AWS Organizations set up
- IAM Identity Center enabled
- SSO users and/or groups created

## Config file

SSO profile settings belong in `~/.aws/config`.

## Method 1 — Recommended (`sso-session`)

Share one `[sso-session …]` across accounts, then point each named profile at that session with its own account and role.

```ini
# ~/.aws/config

[sso-session my-sso]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile account-a]
sso_session = my-sso
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = us-east-1

[profile account-b]
sso_session = my-sso
sso_account_id = 444455556666
sso_role_name = ReadOnlyAccess
region = us-west-2
```

Login once for the session (or via any profile that uses it):

```shell
aws sso login --sso-session my-sso
# or
aws sso login --profile account-a
```

Verify:

```shell
aws sts get-caller-identity --profile account-a
aws sts get-caller-identity --profile account-b
```

## Method 2 — Legacy (inline profile keys)

Put all `sso_*` keys on each `[profile …]` when you are not using an `sso-session` block.

```ini
# ~/.aws/config

[profile account-a]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = us-east-1
```

Login and verify:

```shell
aws sso login --profile account-a
aws sts get-caller-identity --profile account-a
```

## Scripts

- [`sso-profiles-check.sh`](./scripts/sso-profiles-check.sh) — validate local SSO profiles can authenticate
