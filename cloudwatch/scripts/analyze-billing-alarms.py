#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.34",
# ]
# ///
"""Analyze CloudWatch AWS/Billing alarms for misconfiguration and noise.

Read-only: describe alarms + SNS subscriptions across one or more profiles.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

SCRIPT_NAME = "analyze-billing-alarms.py"
BILLING_REGION = "us-east-1"


def log(msg: str) -> None:
    print(f"→ {msg}", file=sys.stderr)


def die(msg: str, code: int) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_region(cli_region: str | None) -> str:
    if cli_region:
        return cli_region
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or BILLING_REGION


@dataclass
class Finding:
    code: str
    severity: str
    detail: str


@dataclass
class AlarmRecord:
    profile: str
    account_id: str
    region: str
    alarm_name: str
    state: str
    namespace: str | None
    metric_name: str | None
    statistic: str | None
    period: int | None
    evaluation_periods: int | None
    threshold: float | None
    comparison_operator: str | None
    treat_missing_data: str | None
    currency: str | None
    service_name: str | None
    dimensions: dict[str, str]
    alarm_actions: list[str]
    sns_topics: list[str]
    findings: list[Finding] = field(default_factory=list)

    def add_finding(self, code: str, severity: str, detail: str) -> None:
        self.findings.append(Finding(code=code, severity=severity, detail=detail))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Analyze CloudWatch AWS/Billing (EstimatedCharges) alarms for "
            "misconfiguration and noise across one or more AWS profiles."
        ),
    )
    p.add_argument("-p", "--profile", default=None, help="AWS CLI/boto3 profile")
    p.add_argument(
        "--profiles",
        default=None,
        help="Comma-separated AWS profiles (scanned in order)",
    )
    p.add_argument("-r", "--region", default=None, help="AWS region (billing metrics expect us-east-1)")
    p.add_argument(
        "-f",
        "--format",
        choices=("table", "json", "markdown"),
        default="table",
        help="Output format (default: table)",
    )
    p.add_argument(
        "--min-threshold",
        type=float,
        default=10.0,
        help="Warn when alarm threshold is at or below this USD value (default: 10)",
    )
    args = p.parse_args(argv)
    if args.min_threshold < 0:
        die("--min-threshold must be >= 0", 1)
    profiles = resolve_profiles(args.profile, args.profiles)
    if not profiles:
        die("Provide -p/--profile and/or --profiles", 1)
    args.profile_list = profiles
    return args


def resolve_profiles(profile: str | None, profiles: str | None) -> list[str]:
    out: list[str] = []
    if profile:
        out.append(profile.strip())
    if profiles:
        for part in profiles.split(","):
            name = part.strip()
            if name and name not in out:
                out.append(name)
    return out


def dimensions_map(alarm: dict[str, Any]) -> dict[str, str]:
    return {d["Name"]: d["Value"] for d in alarm.get("Dimensions") or [] if "Name" in d and "Value" in d}


def is_billing_alarm(alarm: dict[str, Any]) -> bool:
    namespace = alarm.get("Namespace")
    metric = alarm.get("MetricName")
    return namespace == "AWS/Billing" or metric == "EstimatedCharges"


def sns_topic_region(topic_arn: str) -> str | None:
    # arn:aws:sns:region:account:name
    parts = topic_arn.split(":")
    if len(parts) >= 4 and parts[2] == "sns":
        return parts[3]
    return None


def collect_sns_arns(alarm: dict[str, Any]) -> list[str]:
    actions: list[str] = []
    for key in ("AlarmActions", "OKActions", "InsufficientDataActions"):
        for arn in alarm.get(key) or []:
            if isinstance(arn, str) and arn.startswith("arn:aws:sns:") and arn not in actions:
                actions.append(arn)
    return actions


def list_metric_alarms(cw: Any) -> list[dict[str, Any]]:
    alarms: list[dict[str, Any]] = []
    paginator = cw.get_paginator("describe_alarms")
    for page in paginator.paginate(AlarmTypes=["MetricAlarm"]):
        alarms.extend(page.get("MetricAlarms") or [])
    return alarms


def inspect_sns_topic(session: Any, topic_arn: str, cache: dict[str, list[Finding]]) -> list[Finding]:
    if topic_arn in cache:
        return [Finding(f.code, f.severity, f.detail) for f in cache[topic_arn]]

    findings: list[Finding] = []
    region = sns_topic_region(topic_arn) or BILLING_REGION
    sns = session.client("sns", region_name=region)
    try:
        subs: list[dict[str, Any]] = []
        next_token: str | None = None
        while True:
            kwargs: dict[str, Any] = {"TopicArn": topic_arn}
            if next_token:
                kwargs["NextToken"] = next_token
            resp = sns.list_subscriptions_by_topic(**kwargs)
            subs.extend(resp.get("Subscriptions") or [])
            next_token = resp.get("NextToken")
            if not next_token:
                break
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in {"NotFound", "NotFoundException", "ResourceNotFoundException"}:
            findings.append(
                Finding("SNS_TOPIC_MISSING", "error", f"SNS topic not found: {topic_arn}")
            )
        else:
            findings.append(
                Finding(
                    "SNS_TOPIC_MISSING",
                    "error",
                    f"SNS list_subscriptions_by_topic failed for {topic_arn}: {e}",
                )
            )
        cache[topic_arn] = findings
        return [Finding(f.code, f.severity, f.detail) for f in findings]
    except BotoCoreError as e:
        findings.append(
            Finding(
                "SNS_TOPIC_MISSING",
                "error",
                f"SNS list_subscriptions_by_topic failed for {topic_arn}: {e}",
            )
        )
        cache[topic_arn] = findings
        return [Finding(f.code, f.severity, f.detail) for f in findings]

    if not subs:
        findings.append(
            Finding("SNS_NO_SUBSCRIPTIONS", "error", f"SNS topic has no subscriptions: {topic_arn}")
        )
    else:
        pending = [s for s in subs if s.get("SubscriptionArn") == "PendingConfirmation"]
        if pending:
            endpoints = ", ".join(
                f"{s.get('Protocol')}://{s.get('Endpoint')}" for s in pending
            )
            findings.append(
                Finding(
                    "SNS_UNCONFIRMED",
                    "error",
                    f"SNS topic has unconfirmed subscriptions ({endpoints}): {topic_arn}",
                )
            )

    cache[topic_arn] = findings
    return [Finding(f.code, f.severity, f.detail) for f in findings]


def analyze_alarm(
    *,
    alarm: dict[str, Any],
    profile: str,
    account_id: str,
    region: str,
    min_threshold: float,
    session: Any,
    sns_cache: dict[str, list[Finding]],
) -> AlarmRecord:
    dims = dimensions_map(alarm)
    currency = dims.get("Currency")
    service_name = dims.get("ServiceName")
    alarm_actions = list(alarm.get("AlarmActions") or [])
    sns_topics = collect_sns_arns(alarm)

    record = AlarmRecord(
        profile=profile,
        account_id=account_id,
        region=region,
        alarm_name=alarm.get("AlarmName") or "",
        state=alarm.get("StateValue") or "",
        namespace=alarm.get("Namespace"),
        metric_name=alarm.get("MetricName"),
        statistic=alarm.get("Statistic") or alarm.get("ExtendedStatistic"),
        period=alarm.get("Period"),
        evaluation_periods=alarm.get("EvaluationPeriods"),
        threshold=float(alarm["Threshold"]) if alarm.get("Threshold") is not None else None,
        comparison_operator=alarm.get("ComparisonOperator"),
        treat_missing_data=alarm.get("TreatMissingData"),
        currency=currency,
        service_name=service_name,
        dimensions=dims,
        alarm_actions=alarm_actions,
        sns_topics=sns_topics,
    )

    if region != BILLING_REGION:
        record.add_finding(
            "WRONG_REGION",
            "error",
            f"Billing alarms must be evaluated in {BILLING_REGION}; scanned region is {region}",
        )

    if not currency:
        record.add_finding(
            "MISSING_CURRENCY",
            "error",
            "Alarm is missing the Currency dimension",
        )

    expected_shape = (
        record.metric_name == "EstimatedCharges"
        and record.statistic == "Maximum"
        and record.comparison_operator == "GreaterThanOrEqualToThreshold"
    )
    if not expected_shape:
        record.add_finding(
            "UNEXPECTED_SHAPE",
            "warn",
            (
                "Expected EstimatedCharges + Maximum + GreaterThanOrEqualToThreshold; "
                f"got metric={record.metric_name}, statistic={record.statistic}, "
                f"comparison={record.comparison_operator}"
            ),
        )

    if record.threshold is not None and record.threshold <= min_threshold:
        record.add_finding(
            "LOW_THRESHOLD",
            "warn",
            f"Threshold {record.threshold} <= min-threshold {min_threshold} (likely always ALARM)",
        )

    if not alarm_actions:
        record.add_finding(
            "NO_ACTIONS",
            "error",
            "Alarm has no AlarmActions (nothing is notified on ALARM)",
        )

    for topic in sns_topics:
        for finding in inspect_sns_topic(session, topic, sns_cache):
            # Avoid duplicate codes for the same topic detail
            if not any(f.code == finding.code and f.detail == finding.detail for f in record.findings):
                record.findings.append(finding)

    if record.state == "ALARM":
        record.add_finding(
            "STATE_IN_ALARM",
            "warn",
            "Alarm is currently in ALARM state (noise candidate)",
        )

    return record


def duplicate_key(record: AlarmRecord) -> tuple[Any, ...]:
    return (
        record.currency or "",
        record.service_name or "",
        record.metric_name or "",
        record.threshold,
        record.comparison_operator or "",
    )


def flag_cross_account_duplicates(records: list[AlarmRecord]) -> None:
    groups: dict[tuple[Any, ...], list[AlarmRecord]] = defaultdict(list)
    for rec in records:
        groups[duplicate_key(rec)].append(rec)

    for key, group in groups.items():
        accounts = {r.account_id for r in group}
        if len(accounts) < 2:
            continue
        # Prefer groups that share SNS overlap, else still flag same shape/threshold
        sns_sets = [set(r.sns_topics) for r in group]
        overlapping = False
        for i, a in enumerate(sns_sets):
            for b in sns_sets[i + 1 :]:
                if a and b and a.intersection(b):
                    overlapping = True
                    break
            if overlapping:
                break

        account_list = ", ".join(sorted(accounts))
        detail = (
            f"Same billing shape across accounts [{account_list}] "
            f"(Currency={key[0] or 'n/a'}, ServiceName={key[1] or 'n/a'}, "
            f"threshold={key[3]}, comparison={key[4]})"
        )
        if overlapping:
            detail += "; overlapping SNS topics"
        for rec in group:
            rec.add_finding("DUPLICATE_CROSS_ACCOUNT", "warn", detail)


def scan_profile(
    profile: str,
    region: str,
    min_threshold: float,
) -> tuple[str, list[AlarmRecord]]:
    session_kwargs: dict[str, Any] = {"region_name": region}
    if profile:
        session_kwargs["profile_name"] = profile

    log(f"Profile: {profile or '(default)'} | region: {region}")
    try:
        session = boto3.Session(**session_kwargs)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        account_id = identity["Account"]
        log(f"Account: {account_id} ({identity.get('Arn')})")
        cw = session.client("cloudwatch", region_name=region)
        alarms = list_metric_alarms(cw)
    except (ClientError, BotoCoreError) as e:
        die(f"AWS error for profile '{profile}': {e}", 2)

    billing = [a for a in alarms if is_billing_alarm(a)]
    log(f"Found {len(billing)} billing alarm(s) of {len(alarms)} metric alarm(s)")

    sns_cache: dict[str, list[Finding]] = {}
    records: list[AlarmRecord] = []
    for alarm in billing:
        records.append(
            analyze_alarm(
                alarm=alarm,
                profile=profile,
                account_id=account_id,
                region=region,
                min_threshold=min_threshold,
                session=session,
                sns_cache=sns_cache,
            )
        )
    return account_id, records


def count_findings(records: list[AlarmRecord]) -> dict[str, int]:
    counts = {"error": 0, "warn": 0, "info": 0}
    for rec in records:
        for f in rec.findings:
            counts[f.severity] = counts.get(f.severity, 0) + 1
    return counts


def build_ctx(
    *,
    region: str,
    profiles: list[str],
    accounts: list[dict[str, str]],
    records: list[AlarmRecord],
    min_threshold: float,
) -> dict[str, Any]:
    finding_counts = count_findings(records)
    alarms_with_findings = sum(1 for r in records if r.findings)
    summary = [
        f"Scanned {len(profiles)} profile(s) / {len(accounts)} account(s) in {region}.",
        f"Billing alarms: {len(records)} total; {alarms_with_findings} with findings.",
        (
            f"Findings: {finding_counts.get('error', 0)} error, "
            f"{finding_counts.get('warn', 0)} warn "
            f"(min-threshold={min_threshold})."
        ),
    ]
    return {
        "region": region,
        "profiles": profiles,
        "accounts": accounts,
        "min_threshold": min_threshold,
        "alarm_count": len(records),
        "alarms_with_findings": alarms_with_findings,
        "finding_counts": finding_counts,
        "summary": summary,
        "alarms": records,
    }


def fmt_dims(rec: AlarmRecord) -> str:
    parts = []
    if rec.currency:
        parts.append(f"Currency={rec.currency}")
    if rec.service_name:
        parts.append(f"ServiceName={rec.service_name}")
    return ", ".join(parts) if parts else "n/a"


def fmt_findings(rec: AlarmRecord) -> str:
    if not rec.findings:
        return "(none)"
    return "; ".join(f"[{f.severity}] {f.code}: {f.detail}" for f in rec.findings)


def emit_table(ctx: dict[str, Any]) -> None:
    print("Billing CloudWatch Alarms Analysis")
    print("=" * 34)
    for line in ctx["summary"]:
        print(f" - {line}")
    print()
    if not ctx["alarms"]:
        print("No billing alarms found.")
        return

    for rec in ctx["alarms"]:
        print(f"Alarm: {rec.alarm_name}")
        print(f"  Profile/Account: {rec.profile} / {rec.account_id}")
        print(f"  State: {rec.state}")
        print(
            f"  Metric: {rec.namespace}/{rec.metric_name} "
            f"stat={rec.statistic} period={rec.period} "
            f"eval={rec.evaluation_periods}"
        )
        print(
            f"  Condition: {rec.comparison_operator} {rec.threshold} "
            f"(treat_missing_data={rec.treat_missing_data})"
        )
        print(f"  Dimensions: {fmt_dims(rec)}")
        print(f"  SNS: {', '.join(rec.sns_topics) if rec.sns_topics else '(none)'}")
        print(f"  Findings: {fmt_findings(rec)}")
        print()


def emit_markdown(ctx: dict[str, Any]) -> None:
    print("# Billing CloudWatch Alarms Analysis")
    print()
    for line in ctx["summary"]:
        print(f"- {line}")
    print()
    if not ctx["alarms"]:
        print("_No billing alarms found._")
        return

    print("| Account | Alarm | State | Threshold | Dimensions | Findings |")
    print("|---------|-------|-------|-----------|------------|----------|")
    for rec in ctx["alarms"]:
        findings = (
            "<br>".join(f"`{f.severity}` `{f.code}`: {f.detail}" for f in rec.findings)
            if rec.findings
            else "_none_"
        )
        dims = fmt_dims(rec).replace("|", "\\|")
        print(
            f"| {rec.account_id} (`{rec.profile}`) | `{rec.alarm_name}` | {rec.state} | "
            f"{rec.threshold} | {dims} | {findings} |"
        )


def emit_json(ctx: dict[str, Any]) -> None:
    payload = {
        "region": ctx["region"],
        "profiles": ctx["profiles"],
        "accounts": ctx["accounts"],
        "min_threshold": ctx["min_threshold"],
        "summary": ctx["summary"],
        "alarm_count": ctx["alarm_count"],
        "alarms_with_findings": ctx["alarms_with_findings"],
        "finding_counts": ctx["finding_counts"],
        "alarms": [
            {
                **{k: v for k, v in asdict(rec).items() if k != "findings"},
                "findings": [asdict(f) for f in rec.findings],
            }
            for rec in ctx["alarms"]
        ],
    }
    print(json.dumps(payload, indent=2))


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as e:
        return int(e.code) if isinstance(e.code, int) else 1

    region = resolve_region(args.region)
    if region != BILLING_REGION:
        log(
            f"Warning: billing metrics are only published in {BILLING_REGION}; "
            f"using {region} as requested"
        )

    all_records: list[AlarmRecord] = []
    accounts: list[dict[str, str]] = []

    for profile in args.profile_list:
        account_id, records = scan_profile(profile, region, args.min_threshold)
        accounts.append({"profile": profile, "account_id": account_id})
        all_records.extend(records)

    flag_cross_account_duplicates(all_records)
    ctx = build_ctx(
        region=region,
        profiles=args.profile_list,
        accounts=accounts,
        records=all_records,
        min_threshold=args.min_threshold,
    )

    log("Done.")
    print("", file=sys.stderr)
    if args.format == "table":
        emit_table(ctx)
    elif args.format == "markdown":
        emit_markdown(ctx)
    else:
        emit_json(ctx)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
