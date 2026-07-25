# Install AWS CLI v2

Prefer **AWS CLI v2**. v1 still exists on PyPI but is legacy; new setups should install v2.

## Linux

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

Confirm the version:

```shell
aws --version
```

## References

- [Installing or updating the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
