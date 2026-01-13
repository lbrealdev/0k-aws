# AWS CLI

Universal Command Line Interface for Amazon Web Services.

## Install AWS CLI v2

Download the `awscliv2` package from amazon using curl:
```shell
curl -fsSLo "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
```

Extract the installer from the zip file:
```shell
unzip -q awscliv2.zip
```

Run the installation binary as a sudo user:
```shell
sudo ./aws/install
```

After the installation process is complete, run the following command to get the cli version:
```shell
aws --version
```

## References

- [AWS CLI Repository](https://github.com/aws/aws-cli)
- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/)
- [What is the AWS Command Line Interface?](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html)
- [Installing or updating to the latest version of the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Authenticating with short-term credentials for the AWS CLI](https://docs.aws.amazon.com/cli/v1/userguide/cli-authentication-short-term.html)
