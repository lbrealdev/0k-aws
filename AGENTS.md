# 0k-aws — Development Guide

## Git Conventions

- Branch from `main`; do not commit or push directly to `main`
- Use [Conventional Commits](https://www.conventionalcommits.org/), for example `docs(auth):`, `fix(scripts):`, `feat(scripts):`
- Keep commits focused; one logical change per commit when practical

## Code Standards

### Scripts

- Use `#!/bin/bash` and `set -euo pipefail` (some older helpers use `#!/usr/bin/env bash`; new scripts should follow this file)
- Every `*.sh` must support `--help` / `-h` (print usage and exit 0)
- `--help` / usage text must not list dependencies; check tools at runtime instead
- Prefer read-only helpers for inventory and discovery
- Write scripts should support `--dry-run` where practical and make side effects obvious
- For AWS CLI scripts, prefer explicit `--profile` / `--region` over relying on shell defaults
- Quote every expansion passed to `aws`, `jq`, and `printf`; prefer `"${array[@]}"` over unquoted extras
- Errors and usage go to stderr; data/tables go to stdout so the output can be piped
- Check `command -v aws` (and `jq` when used) before the first AWS call; fail with a clear message
- When a script takes a named `--profile`, refuse `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` if those would override the profile (boto3 and some CLI chains honor env first)

### Argument parsing

- `while [[ $# -gt 0 ]]; do case $1 in ... esac; done` then `main` (see `scripts/aws-sso-check.sh`)
- Unknown flags: print error + usage to stderr, exit 1
- Mutually exclusive flags should be rejected explicitly, not silently ignored
- Keep `--help` line width at 80 columns or less

### Printing and logging

Status and data are separated, and caller/config-derived strings are untrusted for terminal output. `scripts/lib/ui.sh` owns the mechanics; source it from every script.

- Banner, one-line header, and status rows go to stderr. stdout carries only pipeable data and the `--dry-run` plan
- `-q` / `--quiet` drops the banner/header and every non-error status row; warnings and errors still print on stderr
- Color only when `NO_COLOR` is unset AND the file descriptor being written is a TTY (`ui_color NAME [fd]`, default fd 2). A pipe and `NO_COLOR=1` stay pure text on both streams
- Emit data with `printf '%s'` (or `printf '%s\n'`). Do not `echo -e` (or `echo -en`) with caller/config-derived strings: `\n`, `\e`, `\c` and friends are interpreted even when the expansion is quoted
- Escape (`ui_esc_data` / `ui_unesc_data`) only on human-facing status lines, never on data, tables, CSV, JSON, or report files. It must be reversible for **any** byte, including ASCII SUB (`0x1a`). Doubling backslashes is not enough (`\e[31m` still matches inside `\\e`). Width math uses `ui_visible_plain` (the decoded visible string)
- Mask secrets (`AWS_SECRET_ACCESS_KEY`, session tokens): never print them in full

Each script resolves the helper from its own path (`dirname "${BASH_SOURCE[0]}"`), walking parents until it finds `scripts/lib/ui.sh`, then exits 1 with a clear stderr message if missing. A script copied alone (for example into CloudShell) will not find the helper unless `scripts/lib/` is copied with the script.

Banner text and column layout stay in the script; the helper owns TTY, `NO_COLOR`, quiet, stream choice, and the escape. Use a full banner only on write scripts; simple read-only scripts get a one-line header (`ui_header`).

Scripts that moved a status line from stdout to stderr: `scripts/aws-sso-check.sh`, `scripts/aws-codecommit-gitconfig.sh`, `scripts/aws-devtools-report.sh`, `scripts/aws-account-list-resources.sh`, `scripts/aws-rds-modify-snapshot.sh`, `scripts/aws-s3-bucket-object.sh`.

### Testing

There is no CI workflow yet. Before opening a PR that touches scripts:

- `bash -n path/to/script.sh`
- `shellcheck path/to/script.sh` when `shellcheck` is on `PATH` (zero findings)
- `python3 -m py_compile path/to/script.py` for Python helpers
- For `aws-sso-check.sh` rendering changes: `tests/aws-sso-check-render.sh` (TTY and non-TTY; includes a `0x1a` path/profile)
- For status/color/stream changes: `tests/ui-render.sh` (every shell script; `--help`, pipe, `NO_COLOR=1`, `--quiet`)
- Scripts whose source is grepped for non-ASCII (token-safe renderers) must stay `LC_ALL=C grep -nP '[^\x00-\x7F]'`-clean

### Docs

- Each top-level area has a `README.md` index; new guides and scripts get a row or bullet there
- Executable helpers also belong in `scripts/README.md` (or the area's `scripts/README.md`) with **read-only** vs **write**
- Do not put credentials, account IDs from real engagements, or live dollar amounts in docs; sanitize examples

### Python

- Prefer a uv [inline script](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies) (PEP 723) when third-party deps are required (`boto3`)
- `--help` via argparse; exit 0 on help, 1 on usage, 2 on AWS errors (match the CloudWatch helpers in `scripts/`)
- Do not log credentials or full session tokens; named profiles over implicit env
