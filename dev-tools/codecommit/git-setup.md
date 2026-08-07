# AWS CodeCommit

## Working with AWS CodeCommit

### Prerequisites

- Git - Git with the `.gitconfig` properly configured
- AWS CLI v2 - AWS CodeCommit has a native helper that only works with AWS CLI version 2
- AWS IAM Role - IAM role that contains `AWSCodeCommitReadOnly` or `AWSCodeCommitPowerUser`

### Git Config

For Git Bash setups where Git Credential Manager (GCM) intercepts CodeCommit HTTPS
auth, use [`./setup-cc-gitconfig.sh`](./setup-cc-gitconfig.sh). The default run is
**check-only** (mutates nothing). Mutating modes (`--fix-system`, `--migrate`)
back up to `~/gitconfig-backups/` before writing.

```shell
# check only (default — mutates nothing)
./setup-cc-gitconfig.sh

# writable system gitconfig: remove system credential.helper (GCM)
./setup-cc-gitconfig.sh --fix-system

# read-only system gitconfig: merge into global + GIT_CONFIG_NOSYSTEM
./setup-cc-gitconfig.sh --migrate
```

**Preferred stack:** Git + AWS CLI v2 + HTTPS remotes with
`aws codecommit credential-helper` — not console **HTTPS (GRC)** /
[`git-remote-codecommit`](https://github.com/aws/git-remote-codecommit)
(extra Python dependency; little upstream activity since ~2023; unnecessary when
git + AWS CLI v2 already support CodeCommit HTTPS).

URL-scoped credential helper (set as part of normal AWS/Git setup; the script
does not write these for you). Git Bash: use **single quotes** with `git config`
per the AWS Windows HTTPS docs.

```ini
[credential "https://git-codecommit.us-east-1.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true

[credential "https://git-codecommit.us-east-2.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true
```

Or a wildcard covering CodeCommit hosts:

```ini
[credential "https://git-codecommit.*.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true
```

```shell
git config --global credential.https://git-codecommit.*.amazonaws.com.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
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
