# Login

The AWS CLI has no native `aws login` or `aws logout` command. How you sign in depends on the credential method:

- SSO / IAM Identity Center: `aws sso login`, end the session with `aws sso logout`
- Long-term keys: stored once by `aws configure`, no login command

```shell
aws sso login --profile <profile>
aws sso logout --profile <profile>
```

Verify who you are:

```shell
aws sts get-caller-identity --profile <profile>
```

See [SSO](./sso.md) for profile setup and [configure](./configure.md) for stored credentials.
