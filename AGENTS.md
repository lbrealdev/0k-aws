# 0k-aws — Development Guide

## Git Conventions

- Branch from `main`; do not commit or push directly to `main`
- Use [Conventional Commits](https://www.conventionalcommits.org/), for example `docs(auth):`, `fix(scripts):`, `feat(scripts):`
- Keep commits focused; one logical change per commit when practical

## Code Standards

### Scripts

- Use `#!/bin/bash` and `set -euo pipefail`
- Every `*.sh` must support `--help` / `-h` (print usage and exit 0)
- Prefer read-only helpers for inventory and discovery
- Write scripts should support `--dry-run` where practical and make side effects obvious
- For AWS CLI scripts, prefer explicit `--profile` / `--region` over relying on shell defaults
