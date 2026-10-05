# AWS Authentication

Methods for authenticating with AWS:

- [AWS SSO](./sso.md) — SSO / IAM Identity Center for multi-account access, recommended for organizations
- IAM user — long-term credentials; see [Authenticating using IAM user credentials for the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-authentication-user.html)

## IAM Identity Center references

- [AWS IAM Identity Center FAQs](https://aws.amazon.com/iam/identity-center/faqs/)
- [IAM Identity Center User Guide](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)
- [Organization instances of IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/organization-instances-identity-center.html)
- [Account instances of IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/account-instances-identity-center.html)
- [To enable an instance of IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/enable-identity-center.html#to-enable-identity-center-instance)

## Related CLI references

- [`cli/configure.md`](../cli/configure.md) — credentials and defaults
- [`cli/sso.md`](../cli/sso.md) — SSO / Identity Center commands
- [`cli/sts.md`](../cli/sts.md) — caller identity and temporary credentials
