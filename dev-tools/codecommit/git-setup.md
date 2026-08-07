# AWS CodeCommit

## Prerequisites

- Git configured with a usable `~/.gitconfig`
- AWS CLI v2 (the CodeCommit credential helper ships with CLI v2 only)
- An IAM role or user with `AWSCodeCommitReadOnly` or `AWSCodeCommitPowerUser`

Preferred stack: Git + AWS CLI v2 + HTTPS remotes using `aws codecommit credential-helper`. Console **HTTPS (GRC)** / [`git-remote-codecommit`](https://github.com/aws/git-remote-codecommit) adds a Python dependency, has seen little upstream activity since ~2023, and is unnecessary when git and AWS CLI v2 already speak CodeCommit HTTPS.

## Windows (Git Bash)

Corporate Git for Windows often sets system `credential.helper = manager` (Git Credential Manager). GCM then pops a username/password dialog and blocks CodeCommit HTTPS auth, which expects the AWS CLI credential helper instead.

### Helper script

[`./setup-cc-gitconfig.sh`](./setup-cc-gitconfig.sh) prepares Git Bash so the AWS CLI helper can run without that GCM dialog.

| Mode | Behavior |
| --- | --- |
| Default (check-only) | Reports system/global/effective `credential.helper`, whether the system gitconfig is writable, and whether `GIT_CONFIG_NOSYSTEM` is set. |
| `--fix-system` | If the system gitconfig is writable, removes GCM (manager) helper values from the system `credential.helper`, preserving other helpers. |
| `--migrate` | If the system gitconfig is read-only: merges system settings into the existing global config (skips GCM helpers), appends `export GIT_CONFIG_NOSYSTEM=1` to an existing `~/.bashrc`; reload the shell afterwards to apply it. Requires `~/.gitconfig` and `~/.bashrc` (does not create them). |

Mutating modes back up to `~/gitconfig-backups/` (override with `--backup-dir`) before writing.

Exit codes: `0` success (no effective manager helper, or `--migrate` succeeded); `1` manager still active; `2` usage error, missing prereqs, or unexpected failure.

```shell
# check only (default)
./setup-cc-gitconfig.sh

# writable system gitconfig: remove GCM helpers only (preserve others)
./setup-cc-gitconfig.sh --fix-system

# read-only system gitconfig: merge into global + GIT_CONFIG_NOSYSTEM
./setup-cc-gitconfig.sh --migrate
```

### Manual alternative (URL-scoped helpers)

The script does not write URL-scoped helpers for you. Add them to `~/.gitconfig` as AWS docs recommend. In Git Bash, use **single quotes** with `git config`.

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

## Linux

No GCM in the way on a typical Linux install, so the Windows helper script is not needed. Point Git at the AWS CLI v2 credential helper with the same URL-scoped pattern.

### Credential helper

```ini
[credential "https://git-codecommit.us-east-1.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true

[credential "https://git-codecommit.us-east-2.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true
```

Wildcard variant:

```ini
[credential "https://git-codecommit.*.amazonaws.com"]
        helper = !aws codecommit credential-helper $@
        UseHttpPath = true
```

```shell
git config --global credential.https://git-codecommit.*.amazonaws.com.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

### AWS CLI and IAM

Install AWS CLI v2, set a default region (`aws configure` or environment), and make sure the process can resolve credentials (shared config/credentials, instance/profile role, or `credential_source` where you already use that pattern). The principal needs CodeCommit read or power-user access as listed under [Prerequisites](#prerequisites).

HTTPS with the AWS CLI credential helper is enough for day-to-day clone/push. You do not need HTTPS(GRC) or `git-remote-codecommit` when that helper is configured.

SSH to CodeCommit is another option on Linux; see [Setup for SSH users](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-ssh-unixes.html).

## References

- [Setup for HTTPS users using Git credentials](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-gc.html)
- [Setup steps for HTTPS connections to AWS CodeCommit repositories on Windows with the AWS CLI credential helper](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-https-windows.html)
- [Setup steps for HTTPS connections to AWS CodeCommit with git-remote-codecommit](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-git-remote-codecommit.html)
- [Setup for SSH users on Linux, macOS, or Unix](https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-ssh-unixes.html)
- [Troubleshooting the credential helper and HTTPS connections to AWS CodeCommit](https://docs.aws.amazon.com/codecommit/latest/userguide/troubleshooting-ch.html)
- [Troubleshooting Git credentials and HTTPS connections to AWS CodeCommit](https://docs.aws.amazon.com/codecommit/latest/userguide/troubleshooting-gc.html)
- [git-remote-codecommit (GitHub)](https://github.com/aws/git-remote-codecommit)
- [git-remote-codecommit (PyPI)](https://pypi.org/project/git-remote-codecommit/)
