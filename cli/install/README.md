# Install AWS CLI v2

Prefer **AWS CLI v2**. v1 still exists on PyPI but is legacy; new setups should install v2.

## Methods

| Method | Platforms | When to use |
|--------|-----------|-------------|
| [mise](#mise) | Linux, macOS, Windows, WSL, Git Bash | Default. Same command everywhere, no sudo |
| [Official installer](#official-installer) | Linux | Single system-wide install without mise |

## mise

### Install mise

Install mise from the [official install guide](https://mise.jdx.dev/getting-started.html). In AWS CloudShell, use the pinned binary in [cloudshell/README.md](../../cloudshell/README.md) instead.

### Install the AWS CLI

```shell
mise use -g awscli@latest
```

Same command on Linux, macOS, Windows, WSL, and Git Bash, which is why this is the default.

## Official installer

### Linux

Download the `awscliv2` package (x86_64):

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

## Verify

```shell
aws --version
```

## References

- [Installing or updating the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [mise](https://mise.jdx.dev/)
