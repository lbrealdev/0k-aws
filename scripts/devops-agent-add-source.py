#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.40",
# ]
# ///
"""Add AWS accounts as secondary sources via SSO profiles."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, TextIO

import boto3
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    ProfileNotFound,
    SSOTokenLoadError,
    TokenRetrievalError,
    UnauthorizedSSOTokenError,
)

SCRIPT_NAME = "devops-agent-add-source.py"
ENV_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)
MANAGED_POLICY_ARN = "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
DEFAULT_ROLE_NAME = "DevOpsAgentCrossAccountRole"
SERVICE_PRINCIPAL = "aidevops.amazonaws.com"
SERVICE_CLIENT = "devops-agent"

ASSOCIATE_RETRY_ATTEMPTS = 5
ASSOCIATE_RETRY_BASE_SECONDS = 2.0
VERIFY_LIST_ATTEMPTS = 5
VERIFY_LIST_BASE_SECONDS = 1.0

_SUB = "\x1a"
_SSO_TOKEN_ERRORS: tuple[type[BaseException], ...] = (
    UnauthorizedSSOTokenError,
    SSOTokenLoadError,
    TokenRetrievalError,
)


class HelpFormatter(argparse.RawDescriptionHelpFormatter):
    """Long options only; keep -h with --help."""

    def _format_action_invocation(self, action: argparse.Action) -> str:
        if not action.option_strings:
            return super()._format_action_invocation(action)
        if "--help" in action.option_strings:
            return "-h, --help"
        longs = [o for o in action.option_strings if o.startswith("--")]
        if not longs:
            longs = list(action.option_strings)
        if action.nargs == 0:
            return ", ".join(longs)
        default = self._get_default_metavar_for_optional(action)
        args_string = self._format_args(action, default)
        return ", ".join(f"{opt} {args_string}" for opt in longs)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        print(f"Error: {message}", file=sys.stderr)
        raise SystemExit(1)


def esc_data(value: str) -> str:
    s = value.replace(_SUB, _SUB + "s")
    return s.replace("\\", _SUB + "b")


def unesc_data(value: str) -> str:
    s = value.replace(_SUB + "b", "\\")
    return s.replace(_SUB + "s", _SUB)


def safe_detail(detail: str) -> str:
    return unesc_data(esc_data(detail)).replace("\033", "")


class StatusUI:
    """Short header + status lines on stderr. Color only when stderr is a TTY."""

    def __init__(self, stream: TextIO | None = None) -> None:
        self.stream = stream if stream is not None else sys.stderr
        self.color = (
            os.environ.get("NO_COLOR") is None
            and hasattr(self.stream, "isatty")
            and self.stream.isatty()
        )

    def _paint(self, code: str, text: str) -> str:
        if not self.color:
            return text
        return f"\033[{code}m{text}\033[0m"

    def _emit(self, mark: str, mark_color: str, label: str, detail: str) -> None:
        mark_s = self._paint(mark_color, f"[{mark}]")
        safe = safe_detail(detail) if detail else ""
        print(f"{mark_s} {label:<10} {safe}".rstrip(), file=self.stream)

    def header(self, text: str) -> None:
        print(self._paint("1", text), file=self.stream)

    def ok(self, label: str, detail: str = "") -> None:
        self._emit("ok", "32", label, detail)

    def warn(self, label: str, detail: str = "") -> None:
        self._emit("warn", "33", label, detail)

    def fail(self, label: str, detail: str = "") -> None:
        self._emit("fail", "31", label, detail)

    def skip(self, label: str, detail: str = "") -> None:
        self._emit("skip", "90", label, detail)

    def dry(self, label: str, detail: str = "") -> None:
        self._emit("dry-run", "36", label, detail)

    def summary(self, associated: int, skipped: int, failed: int) -> None:
        detail = f"associated={associated} skipped={skipped} failed={failed}"
        mark = "ok" if failed == 0 else "fail"
        color = "32" if failed == 0 else "31"
        self._emit(mark, color, "summary", detail)


class VerificationError(Exception):
    """Precondition / verification / SSO failure (exit 2)."""


def die_usage(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def reject_env_credentials() -> None:
    present = [name for name in ENV_CREDENTIAL_VARS if os.environ.get(name)]
    if present:
        die_usage(
            "named SSO profiles only (--source / --target); "
            "unset " + " ".join(present)
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = ArgumentParser(
        prog=SCRIPT_NAME,
        usage=(
            f"{SCRIPT_NAME} --agent-space-id ID --source PROFILE "
            f"--target PROFILE [--target PROFILE ...] "
            f"[--region REGION] [--dry-run]"
        ),
        description=(
            "Add AWS accounts as secondary sources to an AWS DevOps Agent "
            "space via SSO profiles."
        ),
        formatter_class=HelpFormatter,
        add_help=False,
    )

    required = p.add_argument_group("required")
    required.add_argument(
        "--agent-space-id",
        "-s",
        required=True,
        metavar="ID",
        dest="agent_space_id",
        help="Agent Space ID",
    )
    required.add_argument(
        "--source",
        required=True,
        metavar="PROFILE",
        help="SSO profile for the primary account (owns the Agent Space)",
    )
    required.add_argument(
        "--target",
        action="append",
        required=True,
        metavar="PROFILE",
        dest="targets",
        help="SSO profile for a secondary account (repeatable)",
    )

    optional = p.add_argument_group("optional")
    optional.add_argument(
        "--region",
        metavar="REGION",
        help="Agent Space region (default: region of --source)",
    )
    optional.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned changes; write nothing",
    )
    optional.add_argument(
        "-h",
        "--help",
        action="help",
        help="Show this help message and exit",
    )

    p.add_argument(
        "--role-name",
        "-r",
        default=DEFAULT_ROLE_NAME,
        metavar="NAME",
        help=argparse.SUPPRESS,
    )
    p.add_argument(
        "--external-id",
        metavar="ID",
        help=argparse.SUPPRESS,
    )
    return p.parse_args(argv)


def session_for_profile(profile: str, region: str | None = None) -> boto3.Session:
    try:
        kwargs: dict[str, Any] = {"profile_name": profile}
        if region:
            kwargs["region_name"] = region
        return boto3.Session(**kwargs)
    except ProfileNotFound as exc:
        raise VerificationError(
            f"profile '{profile}' not found in AWS config; "
            f"check [profile {profile}] with sso_session / sso_account_id / "
            f"sso_role_name / region and a matching [sso-session ...] block"
        ) from exc


def sso_login_hint(profile: str) -> str:
    return f"aws sso login --profile {profile}"


def resolve_account_id(session: boto3.Session, profile: str) -> str:
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except _SSO_TOKEN_ERRORS as exc:
        raise VerificationError(
            f"SSO token missing or expired for profile '{profile}'; "
            f"run '{sso_login_hint(profile)}'"
        ) from exc
    except (ClientError, BotoCoreError) as exc:
        msg = str(exc).lower()
        name = type(exc).__name__.lower()
        if any(
            s in msg or s in name
            for s in (
                "unauthorizedssotoken",
                "ssotokenload",
                "tokenretrieval",
                "token",
                "sso",
                "refresh",
                "expired",
                "unable to locate credentials",
                "error when retrieving token",
            )
        ):
            raise VerificationError(
                f"cannot authenticate profile '{profile}'; "
                f"run '{sso_login_hint(profile)}' ({exc})"
            ) from exc
        raise VerificationError(
            f"STS failed for profile '{profile}': {exc}"
        ) from exc


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


def account_id_from_association(assoc: dict[str, Any]) -> str | None:
    cfg = assoc.get("configuration") or {}
    for key in ("sourceAws", "aws"):
        acct = (cfg.get(key) or {}).get("accountId")
        if acct:
            return acct
    return None


def list_associated_account_ids(
    devops: Any, space_id: str, ui: StatusUI
) -> set[str]:
    ids: set[str] = set()
    for assoc in iter_associations(devops, space_id):
        acct = account_id_from_association(assoc)
        if acct:
            ids.add(acct)
            continue
        assoc_id = assoc.get("associationId") or "?"
        service_id = assoc.get("serviceId") or "?"
        ui.warn(
            "list",
            f"list_associations entry lacks "
            f"configuration.sourceAws/aws.accountId "
            f"(associationId={assoc_id} serviceId={service_id}); "
            f"skip logic cannot see this association",
        )
    return ids


def print_association_summary(associations: list[dict[str, Any]]) -> None:
    for assoc in associations:
        cfg = assoc.get("configuration") or {}
        account = ""
        account_type = ""
        if cfg.get("sourceAws"):
            account = cfg["sourceAws"].get("accountId") or ""
            account_type = cfg["sourceAws"].get("accountType") or "source"
        elif cfg.get("aws"):
            account = cfg["aws"].get("accountId") or ""
            account_type = cfg["aws"].get("accountType") or "monitor"
        print(
            f"{assoc.get('associationId', '')}\t"
            f"{assoc.get('serviceId', '')}\t"
            f"{account}\t{account_type}\t"
            f"{assoc.get('status', '')}"
        )


def verify_prior_associations_retained(
    *,
    devops: Any,
    space_id: str,
    prior: set[str],
    just_added: str,
    ui: StatusUI,
) -> None:
    current = list_associated_account_ids(devops, space_id, ui)
    missing_prior = sorted(prior - current)
    if missing_prior:
        raise VerificationError(
            "associate-service appears to have dropped prior associations "
            f"(missing accountIds: {', '.join(missing_prior)}). "
            "CLI docs warn that associate-service overwrites the existing "
            "association of the same service; refuse to continue. "
            "Verify multi-account behavior before re-running."
        )

    if just_added in current:
        return

    for attempt in range(1, VERIFY_LIST_ATTEMPTS + 1):
        delay = VERIFY_LIST_BASE_SECONDS * (2 ** (attempt - 1))
        ui.warn(
            "verify",
            f"list_associations does not yet include {just_added} "
            f"(attempt {attempt}/{VERIFY_LIST_ATTEMPTS}); "
            f"retrying in {delay:.0f}s",
        )
        time.sleep(delay)
        current = list_associated_account_ids(devops, space_id, ui)
        missing_prior = sorted(prior - current)
        if missing_prior:
            raise VerificationError(
                "associate-service appears to have dropped prior associations "
                f"(missing accountIds: {', '.join(missing_prior)}). "
                "CLI docs warn that associate-service overwrites the existing "
                "association of the same service; refuse to continue. "
                "Verify multi-account behavior before re-running."
            )
        if just_added in current:
            return

    raise VerificationError(
        f"associate-service succeeded for {just_added}, but "
        f"list-associations still does not list that accountId after "
        f"{VERIFY_LIST_ATTEMPTS} polls. Check the Agent Space manually."
    )


def ensure_cross_account_role(
    *,
    iam: Any,
    account_id: str,
    role_name: str,
    trust: dict[str, Any],
    dry_run: bool,
    profile: str,
    ui: StatusUI,
) -> tuple[str, bool]:
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
            ui.dry("iam", f"create-role {role_name}")
            return role_arn, True
        created = iam.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=trust_json,
            Description="AWS DevOps Agent secondary source role",
        )["Role"]
        iam.attach_role_policy(RoleName=role_name, PolicyArn=MANAGED_POLICY_ARN)
        ui.ok("iam", f"created {role_name}")
        return created["Arn"], True

    role_arn = existing["Arn"]
    current_trust = existing.get("AssumeRolePolicyDocument") or {}
    if isinstance(current_trust, str):
        current_trust = json.loads(current_trust)

    trust_updated = False
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
            ui.dry("iam", f"update trust {role_name}")
            trust_updated = True
        else:
            iam.update_assume_role_policy(
                RoleName=role_name,
                PolicyDocument=trust_json,
            )
            ui.ok("iam", f"updated trust on {role_name}")
            trust_updated = True
    else:
        ui.ok("iam", f"role exists with matching trust: {role_name}")

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
            ui.dry("iam", f"attach {MANAGED_POLICY_ARN}")
        else:
            iam.attach_role_policy(RoleName=role_name, PolicyArn=MANAGED_POLICY_ARN)
            ui.ok("iam", f"attached {MANAGED_POLICY_ARN}")
    return role_arn, trust_updated


def _client_error_message(exc: ClientError) -> str:
    err_obj = exc.response.get("Error") or {}
    return str(err_obj.get("Message") or exc)


def _is_passrole_denied(exc: BaseException) -> bool:
    if not isinstance(exc, ClientError):
        return False
    code = (exc.response.get("Error") or {}).get("Code", "")
    msg = _client_error_message(exc).lower()
    if "passrole" in msg or "iam:passrole" in msg:
        return True
    return code in ("AccessDeniedException", "AccessDenied") and "passrole" in msg


def passrole_denied_message(exc: BaseException) -> str:
    return (
        "associate_service failed: missing iam:PassRole on the primary "
        "caller for arn:aws:iam::<PRIMARY_ACCOUNT_ID>:role/* with "
        "iam:PassedToService=aidevops.amazonaws.com (required even though "
        "assumableRoleArn is in the secondary account). "
        f"AWS error: {exc}"
    )


def _is_retryable_associate_error(exc: BaseException) -> bool:
    if _is_passrole_denied(exc):
        return False
    if isinstance(exc, ClientError):
        code = (exc.response.get("Error") or {}).get("Code", "")
        if code in (
            "ConflictException",
            "ThrottlingException",
            "TooManyRequestsException",
            "ServiceUnavailableException",
        ):
            return True
        msg = _client_error_message(exc).lower()
        if any(
            needle in msg
            for needle in (
                "assum",
                "propagat",
                "not ready",
                "not yet",
                "eventually",
            )
        ):
            return True
    return False


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
    retry_on_iam_propagation: bool,
    ui: StatusUI,
) -> tuple[str, str] | None:
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
                SERVICE_CLIENT,
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
        ui.dry("associate", account_id)
        return None

    attempts = ASSOCIATE_RETRY_ATTEMPTS if retry_on_iam_propagation else 1
    last_exc: BaseException | None = None
    for attempt in range(1, attempts + 1):
        try:
            resp = devops.associate_service(
                agentSpaceId=space_id,
                serviceId="aws",
                configuration=configuration,
            )
            assoc = resp.get("association") or {}
            assoc_id = assoc.get("associationId", "")
            status = assoc.get("status", "")
            ui.ok("associate", f"{account_id} {assoc_id} {status}")
            return assoc_id, status
        except (ClientError, BotoCoreError) as exc:
            last_exc = exc
            if _is_passrole_denied(exc):
                raise VerificationError(passrole_denied_message(exc)) from exc
            if attempt >= attempts or not _is_retryable_associate_error(exc):
                raise
            delay = ASSOCIATE_RETRY_BASE_SECONDS * (2 ** (attempt - 1))
            ui.warn(
                "associate",
                f"{account_id} attempt {attempt}/{attempts}: {exc}; "
                f"retry in {delay:.0f}s",
            )
            time.sleep(delay)
    assert last_exc is not None
    raise last_exc


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        code = exc.code
        if code is None or code == 0:
            return 0
        return 1

    reject_env_credentials()
    ui = StatusUI()

    targets: list[str] = []
    seen: set[str] = set()
    for profile in args.targets:
        if profile not in seen:
            targets.append(profile)
            seen.add(profile)

    if not targets:
        die_usage("provide at least one --target")

    associated = 0
    skipped = 0
    failed = 0

    try:
        try:
            primary = session_for_profile(args.source, args.region)
            region = args.region or primary.region_name
            if not region:
                die_usage(
                    "no region: pass --region or set region on the "
                    f"--source profile '{args.source}'"
                )
            primary_acct = resolve_account_id(primary, args.source)
        except VerificationError as exc:
            ui.fail("source", str(exc))
            ui.summary(0, 0, 1)
            return 2

        ui.header(
            f"{SCRIPT_NAME}  space={args.agent_space_id}  "
            f"region={region}  dry_run={args.dry_run}"
        )
        ui.ok("source", f"{args.source} account={primary_acct}")

        devops = primary.client(SERVICE_CLIENT, region_name=region)
        space_id = args.agent_space_id
        trust = trust_document(primary_acct, region, space_id)

        try:
            known_associated = list_associated_account_ids(devops, space_id, ui)
        except (ClientError, BotoCoreError) as exc:
            ui.fail("list", str(exc))
            ui.summary(0, 0, 1)
            return 2

        ui.ok(
            "list",
            "already associated: "
            + (
                ", ".join(sorted(known_associated))
                if known_associated
                else "(none)"
            ),
        )

        for target_profile in targets:
            try:
                target_session = session_for_profile(target_profile)
                account_id = resolve_account_id(target_session, target_profile)

                if account_id == primary_acct:
                    ui.skip(
                        "target",
                        f"{target_profile} same as source {primary_acct}",
                    )
                    skipped += 1
                    continue

                if account_id in known_associated:
                    ui.skip("target", f"{account_id} already associated")
                    skipped += 1
                    continue

                ui.ok("target", f"{target_profile} account={account_id}")
                iam = target_session.client("iam")
                role_arn, retry_iam = ensure_cross_account_role(
                    iam=iam,
                    account_id=account_id,
                    role_name=args.role_name,
                    trust=trust,
                    dry_run=args.dry_run,
                    profile=target_profile,
                    ui=ui,
                )
                if args.dry_run:
                    role_arn = f"arn:aws:iam::{account_id}:role/{args.role_name}"

                result = associate_source(
                    devops=devops,
                    space_id=space_id,
                    account_id=account_id,
                    role_arn=role_arn,
                    external_id=args.external_id,
                    region=region,
                    profile=args.source,
                    dry_run=args.dry_run,
                    retry_on_iam_propagation=retry_iam and not args.dry_run,
                    ui=ui,
                )
                if result is not None:
                    assoc_id, status = result
                    print(f"{account_id}\t{assoc_id}\t{status}")
                    verify_prior_associations_retained(
                        devops=devops,
                        space_id=space_id,
                        prior=known_associated,
                        just_added=account_id,
                        ui=ui,
                    )
                    known_associated.add(account_id)
                associated += 1
            except VerificationError as exc:
                ui.fail("target", str(exc))
                failed += 1
            except (ClientError, BotoCoreError) as exc:
                ui.fail("target", f"{target_profile}: {exc}")
                failed += 1

        if associated == 0 and failed == 0:
            ui.fail("summary", "no target profiles left to associate")
            ui.summary(associated, skipped, 1)
            return 2

        try:
            if args.dry_run:
                print_cmd(
                    [
                        "aws",
                        SERVICE_CLIENT,
                        "list-associations",
                        "--agent-space-id",
                        shell_quote(space_id),
                        "--profile",
                        shell_quote(args.source),
                        "--region",
                        shell_quote(region),
                    ]
                )
                ui.dry("list", "list-associations")
            else:
                print_association_summary(iter_associations(devops, space_id))
                ui.ok("list", "final associations written to stdout")
        except (ClientError, BotoCoreError) as exc:
            ui.fail("list", str(exc))
            failed += 1

        ui.summary(associated, skipped, failed)
        return 2 if failed else 0
    except VerificationError as exc:
        ui.fail("run", str(exc))
        ui.summary(associated, skipped, failed + 1)
        return 2
    except (ClientError, BotoCoreError) as exc:
        ui.fail("run", str(exc))
        ui.summary(associated, skipped, failed + 1)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
