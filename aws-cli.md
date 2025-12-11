# AWS CLI

Universal Command Line Interface for Amazon Web Services.

### Source

- https://github.com/aws/aws-cli

## Install AWS CLI

Download the `awscli` package from amazon using curl:
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

## Related links

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/)
- [Installing or updating to the latest version of the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
