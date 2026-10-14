#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.40",
# ]
# ///
"""Associate target AWS accounts as secondary sources on an existing setup.

SSO profiles only (--source-profile / --target-profile). Account IDs come
from STS get_caller_identity via boto3.Session(profile_name=...); no config
scanning. Verifies each target IAM role (does not create or modify IAM),
then associates from the source profile in one run.

Exit codes: 0 ok, 1 usage, 2 verification/precondition/AWS failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Any, TextIO

import boto3
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    ProfileNotFound,
    TokenRetrievalError,
)

SCRIPT_NAME = "add-secondary-source.py"
ENV_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)

# ---------------------------------------------------------------------------
# AWS API identifiers (vendor-fixed; not user-facing product copy)
# ---------------------------------------------------------------------------
AWS_API_SERVICE_CLIENT = "devops-agent"
AWS_API_SERVICE_ID = "aws"
AWS_API_SERVICE_PRINCIPAL = "aidevops.amazonaws.com"
AWS_API_MANAGED_POLICY_ARN = (
    "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
)
AWS_API_DEFAULT_ROLE_NAME = "DevOpsAgentCrossAccountRole"
AWS_API_SETUP_ARN_FORMAT = (
    "arn:aws:aidevops:{region}:{account_id}:agentspace/{setup_id}"
)

ASSOCIATE_RETRY_ATTEMPTS = 5
ASSOCIATE_RETRY_BASE_SECONDS = 2.0
VERIFY_LIST_ATTEMPTS = 5
VERIFY_LIST_BASE_SECONDS = 1.0

# Reversible escape sentinels (match auth/scripts/aws-sso-check.sh).
_SUB = "\x1a"


class HelpFormatter(argparse.RawDescriptionHelpFormatter):
    """Long options only, except keep -h with --help."""

    def _format_action_invocation(self, action: argparse.Action) -> str:
        if not action.option_strings:
            return super()._format_action_invocation(action)
        if "--help" in action.option_strings:
            return "-h, --help"
        if "--quiet" in action.option_strings:
            return "-q, --quiet"
        longs = [o for o in action.option_strings if o.startswith("--")]
        if not longs:
            longs = list(action.option_strings)
        if action.nargs == 0:
            return ", ".join(longs)
        default = self._get_default_metavar_for_optional(action)
        args_string = self._format_args(action, default)
        return ", ".join(f"{opt} {args_string}" for opt in longs)


class ArgumentParser(argparse.ArgumentParser):
    """Usage/unknown flags exit 1."""

    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        print(f"Error: {message}", file=sys.stderr)
        raise SystemExit(1)


def esc_data(value: str) -> str:
    """Encode untrusted data for status lines (any byte, including SUB)."""
    s = value.replace(_SUB, _SUB + "s")
    s = s.replace("\\", _SUB + "b")
    return s


def unesc_data(value: str) -> str:
    s = value.replace(_SUB + "b", "\\")
    s = s.replace(_SUB + "s", _SUB)
    return s


@dataclass
class StatusUI:
    """Header + status rows on stderr; color only when stderr is a TTY."""

    stream: TextIO = field(default_factory=lambda: sys.stderr)
    quiet: bool = False
    color: bool = field(init=False)

    def __post_init__(self) -> None:
        self.color = (
            not self.quiet
            and os.environ.get("NO_COLOR") is None
            and hasattr(self.stream, "isatty")
            and self.stream.isatty()
        )

    def _paint(self, code: str, text: str) -> str:
        if not self.color:
            return text
        return f"\033[{code}m{text}\033[0m"

    def _emit(self, mark: str, mark_color: str, label: str, detail: str) -> None:
        if self.quiet and mark not in ("fail",):
            return
        # Escape only interpolated detail (profile names, account ids, etc.).
        safe = unesc_data(esc_data(detail)) if detail else ""
        mark_s = self._paint(mark_color, f"[{mark}]")
        line = f"{mark_s:<14} {label:<12} {safe}".rstrip()
        # Width above includes ANSI when colored; keep simple fixed label.
        line = f"{mark_s} {label:<10} {safe}".rstrip()
        print(line, file=self.stream)

    def header(self, text: str) -> None:
        if self.quiet:
            return
        print(self._paint("1", text), file=self.stream)

    def ok(self, label: str, detail: str = "") -> None:
        self._emit("ok", "32", label, detail)

    def warn(self, label: str, detail: str = "") -> None:
        self._emit("warn", "33", label, detail)

    def fail(self, label: str, detail: str = "") -> None:
        # Failures always print (even with --quiet).
        saved = self.quiet
        self.quiet = False
        try:
            self._emit("fail", "31", label, detail)
        finally:
            self.quiet = saved

    def skip(self, label: str, detail: str = "") -> None:
        self._emit("skip", "90", label, detail)

    def dry(self, label: str, detail: str = "") -> None:
        self._emit("dry-run", "36", label, detail)

    def summary(self, associated: int, skipped: int, failed: int) -> None:
        if self.quiet:
            return
        detail = (
            f"associated={associated} skipped={skipped} failed={failed}"
        )
        mark = "ok" if failed == 0 else "fail"
        color = "32" if failed == 0 else "31"
        self._emit(mark, color, "summary", detail)


class VerificationError(Exception):
    """Target/setup precondition failed (exit 2)."""


def die_usage(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def die_verify(ui: StatusUI, label: str, detail: str) -> None:
    ui.fail(label, detail)
    raise VerificationError(detail)


def reject_env_credentials() -> None:
    present = [name for name in ENV_CREDENTIAL_VARS if os.environ.get(name)]
    if present:
        die_usage(
            "named SSO profiles only (--source-profile / --target-profile); "
            "unset " + " ".join(present)
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = ArgumentParser(
        prog=SCRIPT_NAME,
        usage=(
            f"{SCRIPT_NAME} --setup-id ID --source-profile PROFILE "
            f"--region REGION --target-profile PROFILE "
            f"[--target-profile PROFILE ...] [--dry-run] [-q]"
        ),
        description=(
            "Associate target accounts as secondary sources on an existing "
            "setup (SSO profiles only).\n"
            "Verifies each target IAM role; does not create or modify IAM.\n"
            "\n"
            "Exit codes: 0 ok, 1 usage, 2 verification/precondition/AWS."
        ),
        formatter_class=HelpFormatter,
        epilog=(
            "Examples:\n"
            f"  {SCRIPT_NAME} --setup-id <SETUP_ID> \\\n"
            "    --source-profile <SOURCE_SSO> --region us-east-1 \\\n"
            "    --target-profile <TARGET_SSO> --dry-run\n"
            f"  {SCRIPT_NAME} --setup-id <SETUP_ID> \\\n"
            "    --source-profile <SOURCE_SSO> --region us-east-1 \\\n"
            "    --target-profile <TARGET_A> --target-profile <TARGET_B>\n"
            "\n"
            "Advanced: --role-name, --external-id "
            "(see secondary-source/README.md)."
        ),
    )

    required = p.add_argument_group("required")
    required.add_argument(
        "--setup-id",
        "-s",
        required=True,
        metavar="ID",
        dest="setup_id",
        help="Setup ID in the source account",
    )
    required.add_argument(
        "--source-profile",
        required=True,
        metavar="PROFILE",
        help="SSO profile for the source account (owns the setup)",
    )
    required.add_argument(
        "--region",
        required=True,
        metavar="REGION",
        help="Region of the setup",
    )
    required.add_argument(
        "--target-profile",
        action="append",
        required=True,
        metavar="PROFILE",
        dest="target_profiles",
        help="SSO profile for a target account (repeatable)",
    )

    # Land in the same default "options" group as -h/--help (one heading).
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned associate/list calls; write nothing",
    )
    p.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="Hide header/status on stderr (errors still print)",
    )

    p.add_argument(
        "--role-name",
        "-r",
        default=AWS_API_DEFAULT_ROLE_NAME,
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
    """Load a named profile (including sso_session-based SSO profiles)."""
    try:
        kwargs: dict[str, Any] = {"profile_name": profile}
        if region:
            kwargs["region_name"] = region
        return boto3.Session(**kwargs)
    except ProfileNotFound as exc:
        raise VerificationError(
            f"profile '{profile}' not found in AWS config; "
            f"check [profile {profile}] / [sso-session ...]"
        ) from exc


def sso_login_hint(profile: str) -> str:
    return f"aws sso login --profile {profile}"


def resolve_account_id(session: boto3.Session, profile: str) -> str:
    """Account ID via STS only. Clear message when SSO token is missing/expired."""
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except TokenRetrievalError as exc:
        raise VerificationError(
            f"SSO token missing or expired for profile '{profile}'; "
            f"run '{sso_login_hint(profile)}'"
        ) from exc
    except (ClientError, BotoCoreError) as exc:
        msg = str(exc).lower()
        if any(
            s in msg
            for s in (
                "token",
                "sso",
                "refresh",
                "expired",
                "not authorized",
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


def setup_arn(region: str, source_account: str, setup_id: str) -> str:
    return AWS_API_SETUP_ARN_FORMAT.format(
        region=region, account_id=source_account, setup_id=setup_id
    )


def expected_trust_document(
    source_account: str, region: str, setup_id: str
) -> dict[str, Any]:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": AWS_API_SERVICE_PRINCIPAL},
                "Action": "sts:AssumeRole",
                "Condition": {
                    "StringEquals": {"aws:SourceAccount": source_account},
                    "ArnLike": {
                        "aws:SourceArn": setup_arn(
                            region, source_account, setup_id
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
    """Dry-run plan on stdout (machine-useful)."""
    print(" ".join(parts))


def iter_associations(client: Any, setup_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"agentSpaceId": setup_id}
        if token:
            kwargs["nextToken"] = token
        resp = client.list_associations(**kwargs)
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
    client: Any, setup_id: str, ui: StatusUI | None = None
) -> set[str]:
    ids: set[str] = set()
    for assoc in iter_associations(client, setup_id):
        acct = account_id_from_association(assoc)
        if acct:
            ids.add(acct)
            continue
        assoc_id = assoc.get("associationId") or "?"
        service_id = assoc.get("serviceId") or "?"
        if ui is not None:
            ui.warn(
                "list",
                f"association lacks accountId "
                f"(associationId={assoc_id} serviceId={service_id})",
            )
    return ids


def print_association_rows(associations: list[dict[str, Any]]) -> None:
    """Machine-useful association rows on stdout."""
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
    client: Any,
    setup_id: str,
    prior: set[str],
    just_added: str,
    ui: StatusUI,
) -> None:
    """Fail if a prior associated account disappeared; poll for the new one."""
    current = list_associated_account_ids(client, setup_id, ui)
    missing_prior = sorted(prior - current)
    if missing_prior:
        die_verify(
            ui,
            "retain",
            "prior associations missing after associate: "
            + ", ".join(missing_prior),
        )

    if just_added in current:
        ui.ok("retain", f"includes {just_added}")
        return

    for attempt in range(1, VERIFY_LIST_ATTEMPTS + 1):
        delay = VERIFY_LIST_BASE_SECONDS * (2 ** (attempt - 1))
        ui.warn(
            "retain",
            f"{just_added} not listed yet "
            f"(attempt {attempt}/{VERIFY_LIST_ATTEMPTS}); "
            f"retry in {delay:.0f}s",
        )
        time.sleep(delay)
        current = list_associated_account_ids(client, setup_id, ui)
        missing_prior = sorted(prior - current)
        if missing_prior:
            die_verify(
                ui,
                "retain",
                "prior associations missing after associate: "
                + ", ".join(missing_prior),
            )
        if just_added in current:
            ui.ok("retain", f"includes {just_added}")
            return

    die_verify(
        ui,
        "retain",
        f"{just_added} still missing from list-associations "
        f"after {VERIFY_LIST_ATTEMPTS} polls",
    )


def verify_target_role(
    *,
    iam: Any,
    account_id: str,
    role_name: str,
    expected_trust: dict[str, Any],
    ui: StatusUI,
) -> str:
    """Require role + trust + managed policy. Return role ARN. No IAM writes."""
    try:
        role = iam.get_role(RoleName=role_name)["Role"]
    except ClientError as exc:
        if (exc.response.get("Error") or {}).get("Code") == "NoSuchEntity":
            raise VerificationError(
                f"target {account_id}: missing IAM role '{role_name}'"
            ) from exc
        raise

    role_arn = role["Arn"]
    current_trust = role.get("AssumeRolePolicyDocument") or {}
    if isinstance(current_trust, str):
        current_trust = json.loads(current_trust)

    if canonical_json(current_trust) != canonical_json(expected_trust):
        raise VerificationError(
            f"target {account_id}: role '{role_name}' trust policy mismatch "
            f"(expected SourceAccount/SourceArn for this setup)"
        )

    attached = {
        p["PolicyArn"]
        for p in iam.list_attached_role_policies(RoleName=role_name).get(
            "AttachedPolicies", []
        )
    }
    if AWS_API_MANAGED_POLICY_ARN not in attached:
        raise VerificationError(
            f"target {account_id}: role '{role_name}' missing managed policy "
            f"{AWS_API_MANAGED_POLICY_ARN}"
        )

    ui.ok("role", f"{account_id} {role_name}")
    return role_arn


def _client_error_message(exc: ClientError) -> str:
    err_obj = exc.response.get("Error") or {}
    return str(err_obj.get("Message") or exc)


def _is_passrole_denied(exc: BaseException) -> bool:
    if not isinstance(exc, ClientError):
        return False
    msg = _client_error_message(exc).lower()
    return "passrole" in msg or "iam:passrole" in msg


def passrole_denied_message(exc: BaseException) -> str:
    return (
        "missing iam:PassRole on the source caller for "
        "arn:aws:iam::<SOURCE_ACCOUNT_ID>:role/* with "
        "iam:PassedToService="
        f"{AWS_API_SERVICE_PRINCIPAL} (role ARN is in the target account). "
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
    client: Any,
    setup_id: str,
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
                AWS_API_SERVICE_CLIENT,
                "associate-service",
                "--agent-space-id",
                shell_quote(setup_id),
                "--service-id",
                AWS_API_SERVICE_ID,
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
            resp = client.associate_service(
                agentSpaceId=setup_id,
                serviceId=AWS_API_SERVICE_ID,
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
    ui = StatusUI(quiet=args.quiet)

    targets: list[str] = []
    seen_profiles: set[str] = set()
    for profile in args.target_profiles:
        if profile not in seen_profiles:
            targets.append(profile)
            seen_profiles.add(profile)

    if not targets:
        die_usage("provide at least one --target-profile")

    associated = 0
    skipped = 0
    failed = 0

    try:
        ui.header(
            f"{SCRIPT_NAME}  setup={args.setup_id}  "
            f"region={args.region}  dry_run={args.dry_run}"
        )

        try:
            source_session = session_for_profile(
                args.source_profile, args.region
            )
            source_acct = resolve_account_id(
                source_session, args.source_profile
            )
        except VerificationError as exc:
            ui.fail("source", str(exc))
            ui.summary(0, 0, 1)
            return 2

        ui.ok("source", f"{args.source_profile} account={source_acct}")

        client = source_session.client(
            AWS_API_SERVICE_CLIENT, region_name=args.region
        )
        setup_id = args.setup_id
        trust = expected_trust_document(source_acct, args.region, setup_id)

        try:
            known_associated = list_associated_account_ids(
                client, setup_id, ui
            )
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
                account_id = resolve_account_id(
                    target_session, target_profile
                )

                if account_id == source_acct:
                    ui.skip(
                        "target",
                        f"{target_profile} same as source {source_acct}",
                    )
                    skipped += 1
                    continue

                if account_id in known_associated:
                    ui.skip("target", f"{account_id} already associated")
                    skipped += 1
                    continue

                ui.ok("target", f"{target_profile} account={account_id}")
                iam = target_session.client("iam")
                role_arn = verify_target_role(
                    iam=iam,
                    account_id=account_id,
                    role_name=args.role_name,
                    expected_trust=trust,
                    ui=ui,
                )

                result = associate_source(
                    client=client,
                    setup_id=setup_id,
                    account_id=account_id,
                    role_arn=role_arn,
                    external_id=args.external_id,
                    region=args.region,
                    profile=args.source_profile,
                    dry_run=args.dry_run,
                    retry_on_iam_propagation=False,
                    ui=ui,
                )
                if result is not None:
                    assoc_id, status = result
                    print(f"{account_id}\t{assoc_id}\t{status}")
                    verify_prior_associations_retained(
                        client=client,
                        setup_id=setup_id,
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
                        AWS_API_SERVICE_CLIENT,
                        "list-associations",
                        "--agent-space-id",
                        shell_quote(setup_id),
                        "--profile",
                        shell_quote(args.source_profile),
                        "--region",
                        shell_quote(args.region),
                    ]
                )
                ui.dry("list", "list-associations")
            else:
                print_association_rows(iter_associations(client, setup_id))
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
