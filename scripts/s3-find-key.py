#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.34",
# ]
# ///
"""Find which S3 bucket in the account holds an exact object key.

Read-only. Lists buckets, resolves each bucket region, then HEAD/list
the key.

Exit codes: 0 completed, 1 usage, 2 AWS error.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any, Literal

import boto3
from botocore.exceptions import BotoCoreError, ClientError

SCRIPT_NAME = "s3-find-key.py"
CONTROL_REGION = "us-east-1"
ENV_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)

Probe = Literal["found", "missing", "denied"]


def die(msg: str, code: int) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def log(msg: str) -> None:
    print(f"-> {msg}", file=sys.stderr)


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        die(message, 1)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = _Parser(
        prog=SCRIPT_NAME,
        formatter_class=lambda prog: argparse.RawDescriptionHelpFormatter(
            prog, width=80
        ),
        description=(
            "Find which S3 bucket in this account holds an exact object key\n"
            "(read-only). Lists all buckets, resolves each bucket's region,\n"
            "then tests the key with HeadObject (ListObjectsV2 fallback).\n"
            "\n"
            "Auth: prefer -p/--profile (SSO). If --profile is set, unset\n"
            "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN\n"
            "(boto3 would let env override the profile)."
        ),
        epilog=(
            "Examples:\n"
            f"  {SCRIPT_NAME} --key data/pipeline/output.json -p my-sso\n"
            f"  {SCRIPT_NAME} --key data/pipeline/output.json --prefix backups-"
        ),
    )
    p.add_argument(
        "--key",
        required=True,
        help="Exact S3 object key (e.g. data/pipeline/output.json)",
    )
    p.add_argument(
        "--prefix",
        default=None,
        help="Only check buckets whose names start with this prefix",
    )
    p.add_argument(
        "-p",
        "--profile",
        default=None,
        help="Named SSO profile (account selector)",
    )
    args = p.parse_args(argv)

    key = args.key.strip()
    if not key:
        die("--key must be a non-empty object key", 1)
    if key.startswith("s3://"):
        die("--key is an object key, not an s3:// URI", 1)
    args.key = key

    if args.prefix is not None and args.prefix == "":
        args.prefix = None

    if args.profile is not None:
        profile = args.profile.strip()
        args.profile = profile or None

    return args


def reject_env_credentials() -> None:
    present = [name for name in ENV_CREDENTIAL_VARS if os.environ.get(name)]
    if present:
        die(
            "named profile only (-p/--profile); unset "
            + ", ".join(present)
            + " (env credentials override the profile in boto3's default chain)",
            1,
        )


def make_session(profile: str | None) -> Any:
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def client_error_code(exc: ClientError) -> str:
    err = exc.response.get("Error") or {}
    return str(err.get("Code") or "")


def http_status(exc: ClientError) -> int | None:
    meta = exc.response.get("ResponseMetadata") or {}
    status = meta.get("HTTPStatusCode")
    return int(status) if status is not None else None


def is_not_found(exc: ClientError) -> bool:
    code = client_error_code(exc)
    status = http_status(exc)
    return code in {"404", "NotFound", "NoSuchKey", "NoSuchBucket"} or status == 404


def is_access_denied(exc: ClientError) -> bool:
    code = client_error_code(exc)
    status = http_status(exc)
    return (
        code in {"403", "AccessDenied", "Forbidden", "AllAccessDisabled"}
        or status == 403
    )


def normalize_location(constraint: str | None) -> str:
    if not constraint:
        return "us-east-1"
    if constraint == "EU":
        return "eu-west-1"
    return constraint


def list_bucket_names(s3: Any) -> list[str]:
    resp = s3.list_buckets()
    names = [b["Name"] for b in resp.get("Buckets") or [] if b.get("Name")]
    names.sort()
    return names


def bucket_region(s3: Any, bucket: str) -> str | None:
    try:
        resp = s3.get_bucket_location(Bucket=bucket)
    except ClientError as e:
        if is_access_denied(e):
            log(f"AccessDenied: {bucket} (GetBucketLocation)")
            return None
        log(f"skip {bucket}: GetBucketLocation: {client_error_code(e) or e}")
        return None
    except BotoCoreError as e:
        log(f"skip {bucket}: GetBucketLocation: {e}")
        return None
    return normalize_location(resp.get("LocationConstraint"))


def object_exists(s3: Any, bucket: str, key: str) -> Probe:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return "found"
    except ClientError as e:
        if is_not_found(e):
            return "missing"
        if not is_access_denied(e):
            log(f"skip {bucket}: HeadObject: {client_error_code(e) or e}")
            return "denied"
    except BotoCoreError as e:
        log(f"skip {bucket}: HeadObject: {e}")
        return "denied"

    try:
        resp = s3.list_objects_v2(Bucket=bucket, Prefix=key, MaxKeys=1)
    except ClientError as e:
        if is_access_denied(e):
            log(f"AccessDenied: {bucket} (HeadObject/ListBucket)")
            return "denied"
        if is_not_found(e):
            return "missing"
        log(f"skip {bucket}: ListObjectsV2: {client_error_code(e) or e}")
        return "denied"
    except BotoCoreError as e:
        log(f"skip {bucket}: ListObjectsV2: {e}")
        return "denied"

    for obj in resp.get("Contents") or []:
        if obj.get("Key") == key:
            return "found"
    return "missing"


def find_key(
    session: Any,
    key: str,
    bucket_prefix: str | None,
) -> tuple[list[str], int, int]:
    control = session.client("s3", region_name=CONTROL_REGION)
    try:
        buckets = list_bucket_names(control)
    except ClientError as e:
        die(f"AWS error listing buckets: {e}", 2)
    except BotoCoreError as e:
        die(f"AWS error listing buckets: {e}", 2)

    if bucket_prefix:
        buckets = [b for b in buckets if b.startswith(bucket_prefix)]

    log(f"checking {len(buckets)} bucket(s) for key {key}")

    regional: dict[str, Any] = {}
    matches: list[str] = []
    denied = 0
    missing = 0

    for bucket in buckets:
        region = bucket_region(control, bucket)
        if region is None:
            denied += 1
            continue
        if region not in regional:
            regional[region] = session.client("s3", region_name=region)
        result = object_exists(regional[region], bucket, key)
        if result == "found":
            matches.append(bucket)
        elif result == "denied":
            denied += 1
        else:
            missing += 1

    return matches, denied, missing


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as e:
        if e.code in (0, None):
            return 0
        return 1

    if args.profile:
        reject_env_credentials()

    try:
        session = make_session(args.profile)
    except (BotoCoreError, ClientError) as e:
        die(f"AWS error creating session: {e}", 2)

    matches, denied, missing = find_key(session, args.key, args.prefix)

    for bucket in matches:
        print(f"{bucket}  {args.key}")

    log(
        f"done: {len(matches)} match(es), {missing} not found, "
        f"{denied} AccessDenied/skipped"
    )
    if not matches:
        print(f"No bucket contains key {args.key}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
