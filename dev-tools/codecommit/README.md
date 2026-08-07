# AWS CodeCommit

Notes and helpers for working with AWS CodeCommit from this repo.

## Contents

| Path | What it is |
| --- | --- |
| [git-setup.md](./git-setup.md) | Git + AWS CLI HTTPS setup: **Windows (Git Bash)** (GCM / helper script) and **Linux** (native credential-helper) |
| [setup-cc-gitconfig.sh](./setup-cc-gitconfig.sh) | Windows Git Bash helper: check-only by default; `--fix-system` or `--migrate` when system GCM blocks CodeCommit HTTPS |

> [!TIP]
> Start with [git-setup.md](./git-setup.md). Use the script only on Windows Git Bash when Git Credential Manager intercepts CodeCommit auth.

## Related

- [CLI commands (CodeCommit)](../../cli/codecommit.md)

## References

- [What is AWS CodeCommit?](https://docs.aws.amazon.com/codecommit/latest/userguide/welcome.html)
- [AWS CLI reference: CodeCommit](https://docs.aws.amazon.com/cli/latest/reference/codecommit/)
- [AWS managed policies for CodeCommit](https://docs.aws.amazon.com/codecommit/latest/userguide/security-iam-awsmanpol.html)
