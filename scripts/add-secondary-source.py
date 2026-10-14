#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.40",
# ]
# ///
"""Associate target AWS accounts as secondary sources on an existing setup.

SSO profiles only. --source-profile owns the setup; each --target-profile is
a target account (account ID from STS). Verifies the cross-account IAM role
in each target (does not create or modify IAM), then associates from the
source profile. One invocation runs checks, association, retention checks,
and a final listing.

Exit codes (AGENTS.md): 0 help/success, 1 usage, 2 AWS error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

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


class HelpFormatter(argparse.RawDescriptionHelpFormatter):
    """Show long option names only (short aliases still work)."""

    def _format_action_invocation(self, action: argparse.Action) -> str:
        if not action.option_strings:
            return super()._format_action_invocation(action)
        longs = [o for o in action.option_strings if o.startswith("--")]
        if not longs:
            longs = list(action.option_strings)
        if action.nargs == 0:
            return ", ".join(longs)
        default = self._get_default_metavar_for_optional(action)
        args_string = self._format_args(action, default)
        return ", ".join(f"{opt} {args_string}" for opt in longs)


class ArgumentParser(argparse.ArgumentParser):
    """Usage/unknown flags exit 1 (AGENTS.md Python)."""

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
        die(
            "named SSO profiles only (--source-profile / --target-profile); "
            "unset " + " ".join(present),
            1,
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = ArgumentParser(
        prog=SCRIPT_NAME,
        usage=(
            f"{SCRIPT_NAME} --setup-id ID --source-profile PROFILE "
            f"--region REGION --target-profile PROFILE "
            f"[--target-profile PROFILE ...] [--dry-run]"
        ),
        description=(
            "Associate target accounts as secondary sources on an existing "
            "setup (SSO profiles only).\n"
            "Verifies each target IAM role; does not create or modify IAM."
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
            "Advanced: --role-name, --external-id (see secondary-source/README.md).\n"
            "Note: --ou-id was removed; pass explicit --target-profile values "
            "(account IDs come from STS)."
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

    options = p.add_argument_group("options")
    options.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned associate/list calls; write nothing",
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
    kwargs: dict[str, Any] = {"profile_name": profile}
    if region:
        kwargs["region_name"] = region
    return boto3.Session(**kwargs)


def sts_account(session: boto3.Session) -> str:
    return session.client("sts").get_caller_identity()["Account"]


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
                        "aws:SourceArn": setup_arn(region, source_account, setup_id)
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


def list_associated_account_ids(client: Any, setup_id: str) -> set[str]:
    ids: set[str] = set()
    for assoc in iter_associations(client, setup_id):
        acct = account_id_from_association(assoc)
        if acct:
            ids.add(acct)
            continue
        assoc_id = assoc.get("associationId") or "?"
        service_id = assoc.get("serviceId") or "?"
        warn(
            f"list_associations entry lacks "
            f"configuration.sourceAws/aws.accountId "
            f"(associationId={assoc_id} serviceId={service_id}); "
            f"skip logic cannot see this association"
        )
    return ids


def print_association_summary(associations: list[dict[str, Any]]) -> None:
    print("# associations", file=sys.stderr)
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
        if not account:
            assoc_id = assoc.get("associationId") or "?"
            service_id = assoc.get("serviceId") or "?"
            warn(
                f"list_associations entry lacks "
                f"configuration.sourceAws/aws.accountId "
                f"(associationId={assoc_id} serviceId={service_id})"
            )
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
) -> None:
    """Fail if a prior associated account disappeared; poll for the new one."""
    current = list_associated_account_ids(client, setup_id)
    missing_prior = sorted(prior - current)
    if missing_prior:
        die(
            "associate-service appears to have dropped prior associations "
            f"(missing accountIds: {', '.join(missing_prior)}). "
            "Refuse to continue.",
            2,
        )

    if just_added in current:
        return

    for attempt in range(1, VERIFY_LIST_ATTEMPTS + 1):
        delay = VERIFY_LIST_BASE_SECONDS * (2 ** (attempt - 1))
        warn(
            f"list_associations does not yet include {just_added} "
            f"(attempt {attempt}/{VERIFY_LIST_ATTEMPTS}); "
            f"retrying in {delay:.0f}s"
        )
        time.sleep(delay)
        current = list_associated_account_ids(client, setup_id)
        missing_prior = sorted(prior - current)
        if missing_prior:
            die(
                "associate-service appears to have dropped prior associations "
                f"(missing accountIds: {', '.join(missing_prior)}). "
                "Refuse to continue.",
                2,
            )
        if just_added in current:
            return

    die(
        f"associate-service succeeded for {just_added}, but "
        f"list-associations still does not list that accountId after "
        f"{VERIFY_LIST_ATTEMPTS} polls.",
        2,
    )


def verify_list_associations(
    *,
    client: Any,
    setup_id: str,
    region: str,
    profile: str,
    dry_run: bool,
) -> None:
    if dry_run:
        print_cmd(
            [
                "aws",
                AWS_API_SERVICE_CLIENT,
                "list-associations",
                "--agent-space-id",
                shell_quote(setup_id),
                "--profile",
                shell_quote(profile),
                "--region",
                shell_quote(region),
            ]
        )
        return
    print_association_summary(iter_associations(client, setup_id))


def verify_target_role(
    *,
    iam: Any,
    account_id: str,
    role_name: str,
    expected_trust: dict[str, Any],
) -> str:
    """Require role + trust + managed policy. Return role ARN. No IAM writes."""
    try:
        role = iam.get_role(RoleName=role_name)["Role"]
    except ClientError as exc:
        if (exc.response.get("Error") or {}).get("Code") == "NoSuchEntity":
            die(
                f"target {account_id}: missing IAM role '{role_name}' "
                f"(create it in the target account before running this script)",
                2,
            )
        raise

    role_arn = role["Arn"]
    current_trust = role.get("AssumeRolePolicyDocument") or {}
    if isinstance(current_trust, str):
        current_trust = json.loads(current_trust)

    if canonical_json(current_trust) != canonical_json(expected_trust):
        die(
            f"target {account_id}: role '{role_name}' trust policy does not "
            f"match the expected SourceAccount/SourceArn conditions for this "
            f"setup (update the trust policy in the target account)",
            2,
        )

    attached = {
        p["PolicyArn"]
        for p in iam.list_attached_role_policies(RoleName=role_name).get(
            "AttachedPolicies", []
        )
    }
    if AWS_API_MANAGED_POLICY_ARN not in attached:
        die(
            f"target {account_id}: role '{role_name}' is missing managed "
            f"policy {AWS_API_MANAGED_POLICY_ARN} "
            f"(attach it in the target account)",
            2,
        )

    log(f"target {account_id}: role '{role_name}' OK")
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
        "associate_service failed: missing iam:PassRole on the source "
        "caller for arn:aws:iam::<SOURCE_ACCOUNT_ID>:role/* with "
        "iam:PassedToService="
        f"{AWS_API_SERVICE_PRINCIPAL} (required even though the role ARN "
        f"is in the target account). AWS error: {exc}"
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
            return assoc.get("associationId", ""), assoc.get("status", "")
        except (ClientError, BotoCoreError) as exc:
            last_exc = exc
            if _is_passrole_denied(exc):
                raise ClientError(
                    {
                        "Error": {
                            "Code": "AccessDeniedException",
                            "Message": passrole_denied_message(exc),
                        }
                    },
                    "AssociateService",
                ) from exc
            if attempt >= attempts or not _is_retryable_associate_error(exc):
                raise
            delay = ASSOCIATE_RETRY_BASE_SECONDS * (2 ** (attempt - 1))
            warn(
                f"associate_service for {account_id} failed "
                f"(attempt {attempt}/{attempts}): {exc}; "
                f"retrying in {delay:.0f}s (IAM propagation)"
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

    # Deduplicate target profiles while preserving order.
    targets: list[str] = []
    seen_profiles: set[str] = set()
    for profile in args.target_profiles:
        if profile not in seen_profiles:
            targets.append(profile)
            seen_profiles.add(profile)

    if not targets:
        die("provide at least one --target-profile", 1)

    try:
        source_session = session_for_profile(args.source_profile, args.region)
        try:
            source_acct = sts_account(source_session)
        except (ClientError, BotoCoreError):
            die(
                f"source profile '{args.source_profile}' not logged in; "
                f"aws sso login --profile {args.source_profile}",
                1,
            )

        client = source_session.client(
            AWS_API_SERVICE_CLIENT, region_name=args.region
        )
        setup_id = args.setup_id
        trust = expected_trust_document(source_acct, args.region, setup_id)

        known_associated = list_associated_account_ids(client, setup_id)
        log(
            "already associated accounts: "
            + (
                ", ".join(sorted(known_associated))
                if known_associated
                else "(none)"
            )
        )
        log(
            f"source={source_acct} setup={setup_id} "
            f"targets={len(targets)} dry_run={args.dry_run}"
        )

        aws_failed = False
        processed = 0

        for target_profile in targets:
            try:
                target_session = session_for_profile(target_profile)
                try:
                    account_id = sts_account(target_session)
                except (ClientError, BotoCoreError):
                    warn(
                        f"skip '{target_profile}' (not logged in; "
                        f"aws sso login --profile {target_profile})"
                    )
                    continue

                if account_id == source_acct:
                    warn(
                        f"skip '{target_profile}' "
                        f"(same account as source {source_acct})"
                    )
                    continue

                if account_id in known_associated:
                    log(f"skip already associated: {account_id}")
                    continue

                log(f"processing {account_id} via profile {target_profile}")
                iam = target_session.client("iam")
                role_arn = verify_target_role(
                    iam=iam,
                    account_id=account_id,
                    role_name=args.role_name,
                    expected_trust=trust,
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
                    # Role is pre-existing (verify-only); no create/trust write.
                    retry_on_iam_propagation=False,
                )
                processed += 1
                if result is not None:
                    assoc_id, status = result
                    print(f"{account_id}\t{assoc_id}\t{status}")
                    verify_prior_associations_retained(
                        client=client,
                        setup_id=setup_id,
                        prior=known_associated,
                        just_added=account_id,
                    )
                    known_associated.add(account_id)
            except SystemExit:
                raise
            except (ClientError, BotoCoreError) as exc:
                err(f"failed for profile {target_profile}: {exc}")
                aws_failed = True

        log(f"processed={processed}")
        if processed == 0 and not aws_failed:
            die("no target profiles left to associate", 1)

        try:
            verify_list_associations(
                client=client,
                setup_id=setup_id,
                region=args.region,
                profile=args.source_profile,
                dry_run=args.dry_run,
            )
        except (ClientError, BotoCoreError) as exc:
            err(f"list-associations failed: {exc}")
            aws_failed = True

        if args.dry_run:
            log("dry run: nothing changed")
        return 2 if aws_failed else 0
    except SystemExit:
        raise
    except (ClientError, BotoCoreError) as exc:
        err(str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
