# AWS CodeCommit

## Working with AWS CodeCommit

### Prerequisites

- Git - Git with the `.gitconfig` properly configured
- AWS CLI v2 - AWS CodeCommit has a native helper that only works with AWS CLI version 2
- AWS IAM Role - IAM role that contains `AWSCodeCommitReadOnly` or `AWSCodeCommitPowerUser`

### Git Config

```shell

```

### AWS CodeCommit Helper - Git Remote CodeCommit

- https://github.com/aws/git-remote-codecommit
- https://pypi.org/project/git-remote-codecommit/

## References

- [Setup for HTTPS users using Git credentials](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-gc.html)
- [Setup steps for HTTPS connections to AWS CodeCommit with git-remote-codecommit](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-git-remote-codecommit.html)
- [Setup steps for HTTPS connections to AWS CodeCommit repositories on Windows with the AWS CLI credential helper](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-https-windows.html)
- [Troubleshooting the credential helper and HTTPS connections to AWS CodeCommit](https://docs.aws.amazon.com/codecommit/latest/userguide/troubleshooting-ch.html)
- [Troubleshooting Git credentials and HTTPS connections to AWS CodeCommit](https://docs.aws.amazon.com/codecommit/latest/userguide/troubleshooting-gc.html)
