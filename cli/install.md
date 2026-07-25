# Install AWS CLI v2

Prefer **AWS CLI v2**. v1 still exists on PyPI but is legacy; new setups should install v2.

## Linux (x86_64)

Download the `awscliv2` package:

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

## Other platforms

For other platforms and updates, see the official [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

## Next steps

After install, configure credentials and defaults, then authenticate the way your account expects:

- [configure](./configure.md) — `aws configure list`, import access-key CSV
- [login](./login.md) — `aws login` / `aws logout`
- [SSO](./sso.md) — SSO admin / Identity Center related commands
- [STS](./sts.md) — caller identity and temporary credentials
- Broader auth methods: [auth/](../auth/README.md)
