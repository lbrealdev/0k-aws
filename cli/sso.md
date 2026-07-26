# SSO

Profile layouts (`sso-session` and legacy inline): see [auth/sso.md](../auth/sso.md).

```shell
aws sso login --sso-session <session>
aws sso login --profile <profile>
aws sso logout
aws sts get-caller-identity --profile <profile>
aws sso-admin list-instances
```
