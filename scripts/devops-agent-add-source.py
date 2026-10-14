#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.40",
# ]
# ///
"""Add secondary AWS accounts as sources to an existing DevOps Agent Space.

SSO profiles only. Primary (--profile) owns the Agent Space. Each target
account is reached via its SSO profile (sso_account_id in ~/.aws/config),
same discovery idea as find-iam-role.sh.

Per target: ensure cross-account IAM role (trust + AIDevOpsAgentAccessPolicy),
then associate from primary via devops-agent associate_service (serviceId aws,
sourceAws). Official CLI onboarding uses service-id aws for secondary sources;
whether repeated calls keep multiple sourceAws associations is untested here.

Python (uv + boto3) rather than bash: trust-policy JSON and idempotent IAM
are simpler in Python.

Exit codes (AGENTS.md): 0 success/help, 1 usage, 2 AWS error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

SCRIPT_NAME = "devops-agent-add-source.py"
ENV_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)
ACCOUNT_ID_RE = re.compile(r"^\d{12}$")
MANAGED_POLICY_ARN = "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
DEFAULT_ROLE_NAME = "DevOpsAgentCrossAccountRole"
SERVICE_PRINCIPAL = "aidevops.amazonaws.com"
# Agent Space control plane is regional; see Supported Regions in the user guide.
AWS_CONFIG_FILE = Path(
    os.environ.get("AWS_CONFIG_FILE", Path.home() / ".aws" / "config")
)


class ArgumentParser(argparse.ArgumentParser):
    """Usage errors exit 1 (AGENTS.md Python / cloudwatch scripts)."""

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        print(f"Error: {message}", file=sys.stderr)
        raise SystemExit(1)


def log(msg: str) -> None:
    print(f"[INFO]  {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[WARN]  {msg}", file=sys.stderr)


def err(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)


def die(msg: str, code: int = 1) -> None:
    err(msg)
    raise SystemExit(code)


def reject_env_credentials() -> None:
    present = [name for name in ENV_CREDENTIAL_VARS if os.environ.get(name)]
    if present:
        die("SSO profiles only; unset: " + " ".join(present), 1)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Ensure the DevOps Agent cross-account role in each secondary "
            "account (SSO profile), then associate it as a source on an "
            "existing Agent Space."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            f"  {SCRIPT_NAME} --agent-space-id SPACE --role-name ROLE \\\n"
            "    --profile primary --region us-east-1 --dry-run 111122223333\n"
            f"  {SCRIPT_NAME} --agent-space-id SPACE --role-name ROLE \\\n"
            "    --profile primary --region us-east-1 --ou-id ou-xxxx --dry-run\n"
            "\n"
            "Region must be a DevOps Agent Supported Region for the Agent Space.\n"
        ),
    )
    p.add_argument(
        "--agent-space-id",
        "-s",
        required=True,
        dest="agent_space_id",
        help="Existing Agent Space ID (maps to associate-service --agent-space-id)",
    )
    p.add_argument(
        "--role-name",
        "-r",
        default=DEFAULT_ROLE_NAME,
        help=(
            "IAM role name in each secondary account; used to build "
            f"assumableRoleArn (default: {DEFAULT_ROLE_NAME})"
        ),
    )
    p.add_argument(
        "--profile",
        "-p",
        required=True,
        help="Primary account SSO profile (Agent Space owner)",
    )
    p.add_argument(
        "--region",
        required=True,
        help=(
            "Agent Space region (required; DevOps Agent is not available in "
            "every region — see Supported Regions)"
        ),
    )
    p.add_argument(
        "--ou-id",
        help="Add ACTIVE accounts under this Organizations OU (skips already associated)",
    )
    p.add_argument(
        "accounts",
        nargs="*",
        metavar="ACCOUNT_ID",
        help="Explicit secondary account IDs",
    )
    p.add_argument(
        "--target-profile",
        action="append",
        default=[],
        metavar="ACCOUNT=PROFILE",
        help="Explicit account-to-SSO-profile map (repeatable; overrides config)",
    )
    p.add_argument(
        "--external-id",
        help="Optional externalId for sourceAws association",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print IAM, associate-service, and list-associations calls; change nothing",
    )
    return p.parse_args(argv)


def discover_sso_account_profiles(config_path: Path) -> dict[str, str]:
    """Map account ID -> profile name from SSO profiles in AWS config.

    Mirrors find-iam-role.sh discovery; also reads sso_account_id.
    Strips \\r for Git Bash portability.
    """
    mapping: dict[str, str] = {}
    if not config_path.is_file():
        return mapping

    name = ""
    sso = False
    account_id = ""

    def emit() -> None:
        nonlocal name, sso, account_id
        if name and sso and ACCOUNT_ID_RE.match(account_id):
            mapping.setdefault(account_id, name)
        name = ""
        sso = False
        account_id = ""

    text = config_path.read_text(encoding="utf-8", errors="replace")
    for raw in text.splitlines():
        line = raw.replace("\r", "").strip()
        if line.startswith("[") and line.endswith("]"):
            emit()
            body = line[1:-1].strip()
            if body.startswith("profile "):
                name = body[len("profile ") :].strip()
            elif body == "default":
                name = "default"
            else:
                name = ""
            continue
        if not name or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if key in ("sso_session", "sso_start_url", "sso_account_id"):
            sso = True
        if key == "sso_account_id":
            account_id = value
    emit()
    return mapping


def parse_target_profile_overrides(items: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            die(f"invalid --target-profile (want ACCOUNT=PROFILE): {item}")
        acct, _, profile = item.partition("=")
        acct = acct.strip()
        profile = profile.strip()
        if not ACCOUNT_ID_RE.match(acct) or not profile:
            die(f"invalid --target-profile (want ACCOUNT=PROFILE): {item}")
        out[acct] = profile
    return out


def session_for_profile(profile: str, region: str | None = None) -> boto3.Session:
    kwargs: dict[str, Any] = {"profile_name": profile}
    if region:
        kwargs["region_name"] = region
    return boto3.Session(**kwargs)


def sts_account(profile: str) -> str | None:
    """Return account ID if profile is logged in, else None."""
    try:
        return session_for_profile(profile).client("sts").get_caller_identity()[
            "Account"
        ]
    except (ClientError, BotoCoreError):
        return None


def agent_space_arn(region: str, primary_account: str, space_id: str) -> str:
    return f"arn:aws:aidevops:{region}:{primary_account}:agentspace/{space_id}"


def trust_document(primary_account: str, region: str, space_id: str) -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": SERVICE_PRINCIPAL},
                "Action": "sts:AssumeRole",
                "Condition": {
                    "StringEquals": {"aws:SourceAccount": primary_account},
                    "ArnLike": {
                        "aws:SourceArn": agent_space_arn(
                            region, primary_account, space_id
                        )
                    },
                },
            }
        ],
    }


def canonical_json(doc: dict[str, Any]) -> str:
    return json.dumps(doc, separators=(",", ":"), sort_keys=True)


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def print_cmd(parts: list[str]) -> None:
    print(" ".join(parts))


def iter_associations(devops: Any, space_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"agentSpaceId": space_id}
        if token:
            kwargs["nextToken"] = token
        resp = devops.list_associations(**kwargs)
        out.extend(resp.get("associations") or [])
        token = resp.get("nextToken")
        if not token:
            break
    return out


def list_associated_account_ids(devops: Any, space_id: str) -> set[str]:
    ids: set[str] = set()
    for assoc in iter_associations(devops, space_id):
        cfg = assoc.get("configuration") or {}
        for key in ("sourceAws", "aws"):
            acct = (cfg.get(key) or {}).get("accountId")
            if acct:
                ids.add(acct)
    return ids


def print_association_summary(associations: list[dict[str, Any]]) -> None:
    """Stdout: ASSOCIATION_ID\\tSERVICE_ID\\tACCOUNT\\tACCOUNT_TYPE\\tSTATUS."""
    print("# associations", file=sys.stderr)
    for assoc in associations:
        cfg = assoc.get("configuration") or {}
        account = ""
        account_type = ""
        if "sourceAws" in cfg and cfg["sourceAws"]:
            account = cfg["sourceAws"].get("accountId") or ""
            account_type = cfg["sourceAws"].get("accountType") or "source"
        elif "aws" in cfg and cfg["aws"]:
            account = cfg["aws"].get("accountId") or ""
            account_type = cfg["aws"].get("accountType") or "monitor"
        print(
            f"{assoc.get('associationId', '')}\t"
            f"{assoc.get('serviceId', '')}\t"
            f"{account}\t{account_type}\t"
            f"{assoc.get('status', '')}"
        )


def verify_list_associations(
    *,
    devops: Any,
    space_id: str,
    region: str,
    profile: str,
    dry_run: bool,
) -> None:
    """List associations after associate (or print the planned check)."""
    if dry_run:
        print_cmd(
            [
                "aws",
                "devops-agent",
                "list-associations",
                "--agent-space-id",
                shell_quote(space_id),
                "--profile",
                shell_quote(profile),
                "--region",
                shell_quote(region),
            ]
        )
        return
    associations = iter_associations(devops, space_id)
    print_association_summary(associations)


def list_ou_account_ids(org: Any, ou_id: str) -> list[str]:
    ids: list[str] = []
    paginator = org.get_paginator("list_accounts_for_parent")
    for page in paginator.paginate(ParentId=ou_id):
        for acct in page.get("Accounts") or []:
            if acct.get("Status") == "ACTIVE" and ACCOUNT_ID_RE.match(
                acct.get("Id", "")
            ):
                ids.append(acct["Id"])
    return ids


def ensure_cross_account_role(
    *,
    iam: Any,
    account_id: str,
    role_name: str,
    trust: dict[str, Any],
    dry_run: bool,
    profile: str,
) -> str:
    """Create or update the role; attach managed policy. Return role ARN."""
    trust_json = json.dumps(trust)
    role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"
    suffix = ["--profile", shell_quote(profile)]

    existing: dict[str, Any] | None = None
    try:
        existing = iam.get_role(RoleName=role_name)["Role"]
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "NoSuchEntity":
            raise

    if existing is None:
        create_cmd = [
            "aws",
            "iam",
            "create-role",
            "--role-name",
            shell_quote(role_name),
            "--assume-role-policy-document",
            shell_quote(trust_json),
            *suffix,
        ]
        attach_cmd = [
            "aws",
            "iam",
            "attach-role-policy",
            "--role-name",
            shell_quote(role_name),
            "--policy-arn",
            shell_quote(MANAGED_POLICY_ARN),
            *suffix,
        ]
        if dry_run:
            print_cmd(create_cmd)
            print_cmd(attach_cmd)
            return role_arn
        created = iam.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=trust_json,
            Description="AWS DevOps Agent secondary source role",
        )["Role"]
        iam.attach_role_policy(RoleName=role_name, PolicyArn=MANAGED_POLICY_ARN)
        return created["Arn"]

    role_arn = existing["Arn"]
    current_trust = existing.get("AssumeRolePolicyDocument") or {}
    if isinstance(current_trust, str):
        current_trust = json.loads(current_trust)

    if canonical_json(current_trust) != canonical_json(trust):
        cmd = [
            "aws",
            "iam",
            "update-assume-role-policy",
            "--role-name",
            shell_quote(role_name),
            "--policy-document",
            shell_quote(trust_json),
            *suffix,
        ]
        if dry_run:
            print_cmd(cmd)
        else:
            iam.update_assume_role_policy(
                RoleName=role_name,
                PolicyDocument=trust_json,
            )
            log(f"updated trust policy on {role_name}")
    else:
        log(f"role exists with matching trust: {role_name}")

    attached = {
        p["PolicyArn"]
        for p in iam.list_attached_role_policies(RoleName=role_name).get(
            "AttachedPolicies", []
        )
    }
    if MANAGED_POLICY_ARN not in attached:
        cmd = [
            "aws",
            "iam",
            "attach-role-policy",
            "--role-name",
            shell_quote(role_name),
            "--policy-arn",
            shell_quote(MANAGED_POLICY_ARN),
            *suffix,
        ]
        if dry_run:
            print_cmd(cmd)
        else:
            iam.attach_role_policy(RoleName=role_name, PolicyArn=MANAGED_POLICY_ARN)
            log(f"attached {MANAGED_POLICY_ARN}")
    return role_arn


def associate_source(
    *,
    devops: Any,
    space_id: str,
    account_id: str,
    role_arn: str,
    external_id: str | None,
    region: str,
    profile: str,
    dry_run: bool,
) -> tuple[str, str] | None:
    # Official CLI onboarding uses service-id aws + sourceAws for secondary
    # accounts. Docs also say associate-service "overwrites the existing
    # association of the same service" — multi-account retention untested.
    source: dict[str, Any] = {
        "accountId": account_id,
        "accountType": "source",
        "assumableRoleArn": role_arn,
    }
    if external_id:
        source["externalId"] = external_id
    configuration = {"sourceAws": source}

    if dry_run:
        config_json = json.dumps(configuration, separators=(",", ":"))
        print_cmd(
            [
                "aws",
                "devops-agent",
                "associate-service",
                "--agent-space-id",
                shell_quote(space_id),
                "--service-id",
                "aws",
                "--configuration",
                shell_quote(config_json),
                "--profile",
                shell_quote(profile),
                "--region",
                shell_quote(region),
            ]
        )
        return None

    resp = devops.associate_service(
        agentSpaceId=space_id,
        serviceId="aws",
        configuration=configuration,
    )
    assoc = resp.get("association") or {}
    return assoc.get("associationId", ""), assoc.get("status", "")


def collect_account_ids(
    *,
    accounts: list[str],
    ou_id: str | None,
    org: Any | None,
    devops: Any,
    space_id: str,
) -> list[str]:
    targets: list[str] = []
    seen: set[str] = set()

    for acct in accounts:
        if not ACCOUNT_ID_RE.match(acct):
            die(f"invalid account ID: {acct}")
        if acct not in seen:
            targets.append(acct)
            seen.add(acct)

    associated = list_associated_account_ids(devops, space_id)

    if ou_id:
        assert org is not None
        for acct in list_ou_account_ids(org, ou_id):
            if acct in associated:
                log(f"skip already associated: {acct}")
                continue
            if acct not in seen:
                targets.append(acct)
                seen.add(acct)

    filtered: list[str] = []
    for acct in targets:
        if acct in associated:
            log(f"skip already associated: {acct}")
            continue
        filtered.append(acct)
    return filtered


def resolve_target_profile(
    account_id: str,
    overrides: dict[str, str],
    discovered: dict[str, str],
) -> str | None:
    return overrides.get(account_id) or discovered.get(account_id)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        code = exc.code
        if code is None or code == 0:
            return 0
        return int(code) if isinstance(code, int) else 1

    if not args.accounts and not args.ou_id:
        die("provide at least one ACCOUNT_ID or --ou-id")

    reject_env_credentials()
    overrides = parse_target_profile_overrides(args.target_profile)
    discovered = discover_sso_account_profiles(AWS_CONFIG_FILE)
    log(f"SSO account profiles in {AWS_CONFIG_FILE}: {len(discovered)}")

    try:
        if sts_account(args.profile) is None:
            die(
                f"primary profile '{args.profile}' not logged in; "
                f"aws sso login --profile {args.profile}",
                2,
            )

        primary = session_for_profile(args.profile, args.region)
        primary_acct = primary.client("sts").get_caller_identity()["Account"]
        devops = primary.client("devops-agent", region_name=args.region)
        org = primary.client("organizations") if args.ou_id else None
        space_id = args.agent_space_id

        targets = collect_account_ids(
            accounts=list(args.accounts),
            ou_id=args.ou_id,
            org=org,
            devops=devops,
            space_id=space_id,
        )
        if not targets:
            die("no accounts to associate")

        trust = trust_document(primary_acct, args.region, space_id)
        log(
            f"primary={primary_acct} space={space_id} "
            f"targets={len(targets)} dry_run={args.dry_run}"
        )

        aws_failed = False
        scanned = 0
        skipped = 0

        for account_id in targets:
            profile = resolve_target_profile(account_id, overrides, discovered)
            if not profile:
                warn(f"skip '{account_id}' (no SSO profile in {AWS_CONFIG_FILE})")
                skipped += 1
                continue

            logged = sts_account(profile)
            if logged is None:
                warn(
                    f"skip '{profile}' (not logged in; "
                    f"aws sso login --profile {profile})"
                )
                skipped += 1
                continue
            if logged != account_id:
                warn(
                    f"skip '{profile}' "
                    f"(sts account {logged} != expected {account_id})"
                )
                skipped += 1
                continue

            scanned += 1
            log(f"processing {account_id} via profile {profile}")
            try:
                iam = session_for_profile(profile).client("iam")
                role_arn = ensure_cross_account_role(
                    iam=iam,
                    account_id=account_id,
                    role_name=args.role_name,
                    trust=trust,
                    dry_run=args.dry_run,
                    profile=profile,
                )
                if args.dry_run:
                    role_arn = f"arn:aws:iam::{account_id}:role/{args.role_name}"

                result = associate_source(
                    devops=devops,
                    space_id=space_id,
                    account_id=account_id,
                    role_arn=role_arn,
                    external_id=args.external_id,
                    region=args.region,
                    profile=args.profile,
                    dry_run=args.dry_run,
                )
                if result is not None:
                    assoc_id, status = result
                    print(f"{account_id}\t{assoc_id}\t{status}")
            except (ClientError, BotoCoreError) as exc:
                err(f"failed for {account_id}: {exc}")
                aws_failed = True

        log(f"scanned={scanned} skipped={skipped}")

        if scanned == 0:
            die("no reachable SSO profiles for target accounts")

        try:
            verify_list_associations(
                devops=devops,
                space_id=space_id,
                region=args.region,
                profile=args.profile,
                dry_run=args.dry_run,
            )
        except (ClientError, BotoCoreError) as exc:
            err(f"list-associations failed: {exc}")
            aws_failed = True

        if args.dry_run:
            log("dry run: nothing changed")
        return 2 if aws_failed else 0
    except (ClientError, BotoCoreError) as exc:
        err(str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
