# Install AWS CLI

Download the awscli package from amazon using curl:
```shell
curl -SLfs "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
```

Unzip the installer:
```shell
unzip -q awscliv2.zip
```

Run the install program:
```shell
sudo ./aws/install
```

Get aws cli version:
```shell
aws --version
```

### Sources

- [AWS CLI guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
