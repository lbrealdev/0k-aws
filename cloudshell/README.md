# AWS CloudShell

## Tools (persistent mode)

### Mise

Install `mise`:
```shell
curl -fsSLo "mise" "https://github.com/jdx/mise/releases/download/v2025.8.18/mise-v2025.8.18-linux-x64"

chmod +x mise

mv mise ~/.local/bin
```

### Just

Install `just` (pinned via mise, like the rest of this repo):
```shell
mise use -g just
```

## Related links

- [What is AWS CloudShell?](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html)
- [Getting started with AWS CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/getting-started.html)
- [AWS CloudShell compute environment: specifications and software](https://docs.aws.amazon.com/cloudshell/latest/userguide/vm-specs.html#pre-installed-software)