# Install AWS CLI

Download the awscli package from amazon using curl:
```shell
curl -fsSLo "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
```

Unzip the installer:
```shell
unzip -q awscliv2.zip
```

Run the installation binary:
```shell
sudo ./aws/install
```

Print aws cli version:
```shell
aws --version
```

#### Sources

- [AWS CLI guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
