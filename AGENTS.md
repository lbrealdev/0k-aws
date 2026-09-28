# 0k-aws — Agent Contract

## Repo

Personal AWS notes and helper scripts. Branch from `main`; use [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(scripts):`, `docs(auth):`). Do not commit or push directly to `main`.

## Scripts

- `#!/bin/bash` and `set -euo pipefail`
- Every `*.sh` supports `--help` / `-h`
- Prefer read-only inventory/discovery helpers
- Write helpers support `--dry-run` where practical; make side effects obvious
- Prefer explicit `--profile` / `--region` over shell defaults
- If the script takes a named `--profile`, refuse when `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_SESSION_TOKEN` is set (they override the profile)

Python helpers that need third-party deps should be [uv inline scripts](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies) (PEP 723). Match the exit and profile conventions below.

## CLI

- No arguments → short usage plus `Try --help` (or equivalent) on stderr, exit 2. No `[ERROR]` prefix, no full help dump.
- `-h` / `--help` → lean help on stdout, exit 0: **Usage**, brief purpose, **Options** only. No Exit or Examples blocks.

## Exits

Default convention:

| Code | Meaning |
|------|---------|
| 0 | Success / found |
| 1 | Not found / nothing to do / zero SSO profiles |
| 2 | Usage error or hard failure (missing deps / AWS call failed) |

If a script differs, document it in `scripts/README.md` for that script.

## Output

- Data and tables on stdout; logs and errors on stderr
- Default lean logging: `[INFO]`, `[WARN]`, `[ERROR]` — no banners or colors unless the script’s job truly needs richer TTY UI

## Models

For new bash UX and multi-SSO discovery, follow `scripts/find-iam-role.sh`. Borrow SSO config parsing from `auth/scripts/aws-sso-check.sh` only when needed — do not copy its panel/render complexity.

## Docs

New guides and scripts get an entry in the area `README.md` and in `scripts/README.md` (or the area’s `scripts/README.md`), marked **read-only** vs **write**. No real credentials, engagement account IDs, or live dollar amounts in docs.

## Check before PR

- `bash -n` on touched scripts
- `shellcheck` when available (zero findings)
- `python3 -m py_compile` for Python helpers
