# 0k-aws — Agent Contract

## Purpose

Personal AWS notes and helper scripts from day-to-day practical experience: procedures that work, and how AWS behaves in practice.

For coding agents and humans adding guides or helpers to this repo. Out of scope: a general AWS textbook, product marketing, or unrelated cloud platforms.

## Scripts

Contract for shell and Python helpers. Follow it for every new script.

### Scope

Applies to `*.sh` and Python. Python helpers that need third-party deps (including `boto3` for AWS) must be [uv inline scripts](https://docs.astral.sh/uv/guides/scripts/#declaring-script-dependencies) (PEP 723).

Put shared/cross-area helpers under root `scripts/`. Put area-specific helpers under that area’s `scripts/` (e.g. `auth/scripts/`). Add new scripts next to related work; index them as described under Docs.

### Shell baseline

- New shell scripts use `#!/bin/bash` and `set -euo pipefail`.
- Check required tools at runtime with `command -v` before first use; fail clearly on stderr with exit 2.
- Never list dependencies in `--help`.

### Help / CLI

- Every script supports `--help` / `-h` by default.
- No arguments → short usage plus `Try --help` (or equivalent) on stderr, exit 2. No `[ERROR]` prefix, no full help dump.
- Unknown flags follow the same path: short usage plus `Try --help` (or equivalent) on stderr, exit 2. No `[ERROR]` prefix, no full help dump.
- `-h` / `--help` → lean help on stdout, exit 0: **Usage**, brief purpose, **Options** only. No Exit or Examples blocks.

### Auth

Support AWS SSO (primary) and environment credentials — caller’s choice.

- Prefer explicit `--profile` / `--region` when the script uses named profiles.
- If the script exposes `--profile`, refuse when `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_SESSION_TOKEN` is set (they override the profile). Document that only in the script’s entry in `scripts/README.md` or the area `scripts/README.md` — never in `--help`.
- If neither a usable profile nor env credentials are available, fail clearly on stderr with exit 2.

### Exits

| Code | Meaning |
|------|---------|
| 0 | Success / found |
| 1 | Not found / nothing to do / zero SSO profiles |
| 2 | Usage error or hard failure (missing deps / auth / AWS call failed) |

If a script uses different codes, document them in that script’s `scripts/README.md` (or area scripts README) entry.

### Output

- Data and tables on stdout; logs and errors on stderr.
- Default lean logging: `[INFO]`, `[WARN]`, `[ERROR]`.
- No banners or colors unless the script’s job truly needs richer TTY UI.

### Safety

- Prefer read-only inventory and discovery helpers.
- Write helpers support `--dry-run` where practical; make side effects obvious before they run.

### Reference rule

New helpers must follow this Scripts contract (help, auth, exits, output, uv). Prefer the pattern of a newer script that already matches the contract over older ones that do not. Do not treat any single file path as a permanent golden template.

### Check before PR

- `bash -n` on touched shell scripts
- `shellcheck` when available (zero findings)
- `python3 -m py_compile` for Python helpers

## Docs

Documentation contract for guides and script notes — not a folder inventory.

### How to document

Write in a practical tone: prerequisites, SSO/profile/region, the command to run, and a common failure. When a procedure and its script both change, update the docs in the same PR.

### What an area should cover

Enough for someone to run the procedure safely: context, inputs (profile, region, resource ids), steps, expected outcome, and how to recover or stop if something fails. Do not dump every AWS API surface for the service.

### Indexing

New guides and scripts get an entry in the area `README.md` and in `scripts/README.md` (or the area’s `scripts/README.md`), marked **read-only** vs **write**.

### Secrets in docs

Never document real credentials, engagement account IDs, or live dollar amounts. Sanitize examples.

## Git

- Branch from `main`; do not commit or push directly to `main`.
- Use [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(scripts):`, `docs(auth):`).
- Never commit keys, `.env` files, credential dumps, or session tokens.
