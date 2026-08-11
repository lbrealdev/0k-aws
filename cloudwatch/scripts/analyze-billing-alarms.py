#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.34",
# ]
# ///
"""Inventory WARN/CRIT CloudWatch billing alarms and assess CRIT thresholds.

Round 1 (inventory): classify alarms, map linked accounts, mark WARN for removal.
Round 2 (assess): compare CRIT thresholds to last-month spend and AWS Budgets.
"""

from __future__ import annotations

import argparse
import calendar
import json
import os
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

SCRIPT_NAME = "analyze-billing-alarms.py"
BILLING_REGION = "us-east-1"
ACCOUNT_ID_RE = re.compile(r"(?<!\d)(\d{12})(?!\d)")


def log(msg: str) -> None:
    print(f"→ {msg}", file=sys.stderr)


def die(msg: str, code: int) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_region(cli_region: str | None) -> str:
    if cli_region:
        return cli_region
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or BILLING_REGION


def require_profile(profile: str | None) -> str:
    if not profile:
        die("Provide -p/--profile (central SSO profile that holds the alarms)", 1)
    return profile


@dataclass
class Finding:
    code: str
    severity: str
    detail: str


@dataclass
class InventoryAlarm:
    profile: str
    scanner_account_id: str
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
    linked_account_id: str | None
    severity: str
    dimensions: dict[str, str]
    alarm_actions: list[str]
    findings: list[Finding] = field(default_factory=list)

    def add_finding(self, code: str, severity: str, detail: str) -> None:
        self.findings.append(Finding(code=code, severity=severity, detail=detail))


@dataclass
class AssessRow:
    alarm_name: str
    linked_account_id: str | None
    threshold: float | None
    service_name: str | None
    currency: str | None
    last_month_peak: float | None
    budget_limit: float | None
    budget_name: str | None
    verdict: str
    notes: list[str] = field(default_factory=list)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Two-round billing alarm tool: inventory WARN/CRIT CloudWatch alarms, "
            "then assess CRIT thresholds vs last-month spend and AWS Budgets."
        ),
    )
    sub = p.add_subparsers(dest="command", required=True)

    def add_shared(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("-p", "--profile", default=None, help="Central AWS CLI/boto3 profile")
        sp.add_argument("-r", "--region", default=None, help="AWS region (billing metrics expect us-east-1)")
        sp.add_argument(
            "-f",
            "--format",
            choices=("table", "json", "markdown"),
            default="table",
            help="Output format (default: table)",
        )

    inv = sub.add_parser("inventory", help="Round 1: list billing alarms, WARN/CRIT, linked accounts")
    add_shared(inv)

    assess = sub.add_parser("assess", help="Round 2: assess CRIT thresholds vs spend/Budgets")
    add_shared(assess)
    assess.add_argument(
        "--from",
        dest="from_path",
        required=True,
        help="Path to inventory JSON from: inventory -f json",
    )

    return p.parse_args(argv)


def dimensions_map(alarm: dict[str, Any]) -> dict[str, str]:
    return {d["Name"]: d["Value"] for d in alarm.get("Dimensions") or [] if "Name" in d and "Value" in d}


def is_billing_alarm(alarm: dict[str, Any]) -> bool:
    return alarm.get("Namespace") == "AWS/Billing" or alarm.get("MetricName") == "EstimatedCharges"


def parse_severity(alarm_name: str) -> str:
    upper = alarm_name.upper()
    # Prefer CRIT over WARN if both somehow appear; check explicit tokens.
    has_crit = re.search(r"(?<![A-Z])CRIT(?![A-Z])", upper) is not None
    has_warn = re.search(r"(?<![A-Z])WARN(?![A-Z])", upper) is not None
    if has_crit and not has_warn:
        return "CRIT"
    if has_warn and not has_crit:
        return "WARN"
    if has_crit and has_warn:
        return "CRIT"
    return "UNKNOWN"


def resolve_linked_account(alarm_name: str, dims: dict[str, str]) -> tuple[str | None, str | None]:
    """Return (linked_account_id, source) where source is dimension|name|None."""
    if dims.get("LinkedAccount"):
        return dims["LinkedAccount"], "dimension"
    match = ACCOUNT_ID_RE.search(alarm_name)
    if match:
        return match.group(1), "name"
    return None, None


def list_metric_alarms(cw: Any) -> list[dict[str, Any]]:
    alarms: list[dict[str, Any]] = []
    paginator = cw.get_paginator("describe_alarms")
    for page in paginator.paginate(AlarmTypes=["MetricAlarm"]):
        alarms.extend(page.get("MetricAlarms") or [])
    return alarms


def previous_calendar_month_window(now: datetime | None = None) -> tuple[datetime, datetime]:
    now = now or datetime.now(timezone.utc)
    first_this = datetime(now.year, now.month, 1, tzinfo=timezone.utc)
    if now.month == 1:
        start = datetime(now.year - 1, 12, 1, tzinfo=timezone.utc)
    else:
        start = datetime(now.year, now.month - 1, 1, tzinfo=timezone.utc)
    return start, first_this


def make_session(profile: str, region: str) -> Any:
    return boto3.Session(profile_name=profile, region_name=region)


def inventory_alarm_record(
    *,
    alarm: dict[str, Any],
    profile: str,
    scanner_account_id: str,
    region: str,
) -> InventoryAlarm:
    dims = dimensions_map(alarm)
    linked_account_id, link_source = resolve_linked_account(alarm.get("AlarmName") or "", dims)
    severity = parse_severity(alarm.get("AlarmName") or "")

    record = InventoryAlarm(
        profile=profile,
        scanner_account_id=scanner_account_id,
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
        currency=dims.get("Currency"),
        service_name=dims.get("ServiceName"),
        linked_account_id=linked_account_id,
        severity=severity,
        dimensions=dims,
        alarm_actions=list(alarm.get("AlarmActions") or []),
    )

    if region != BILLING_REGION:
        record.add_finding(
            "WRONG_REGION",
            "error",
            f"Billing alarms must be evaluated in {BILLING_REGION}; scanned region is {region}",
        )

    if severity == "WARN":
        record.add_finding(
            "WARN_REMOVE_CANDIDATE",
            "info",
            "WARN billing alarm — approved removal candidate; keep CRIT only",
        )

    if not linked_account_id:
        if "LinkedAccount" not in dims:
            record.add_finding(
                "MISSING_LINKED_ACCOUNT",
                "error",
                "No LinkedAccount dimension and no 12-digit account id in alarm name",
            )
        record.add_finding(
            "UNMAPPED_ACCOUNT",
            "error",
            "Cannot pair alarm to a linked account for spend/Budget assessment",
        )
    elif link_source == "name":
        record.add_finding(
            "LINKED_ACCOUNT_FROM_NAME",
            "info",
            f"Linked account {linked_account_id} inferred from alarm name (no LinkedAccount dimension)",
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

    if not dims.get("Currency"):
        record.add_finding(
            "MISSING_CURRENCY",
            "warn",
            "Alarm is missing the Currency dimension (assessment assumes USD)",
        )

    return record


def run_inventory(profile: str, region: str) -> dict[str, Any]:
    log(f"inventory | profile={profile} region={region}")
    try:
        session = make_session(profile, region)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        scanner_account_id = identity["Account"]
        log(f"Scanner account: {scanner_account_id}")
        cw = session.client("cloudwatch", region_name=region)
        alarms = list_metric_alarms(cw)
    except (ClientError, BotoCoreError) as e:
        die(f"AWS error during inventory: {e}", 2)

    billing = [a for a in alarms if is_billing_alarm(a)]
    log(f"Found {len(billing)} billing alarm(s) of {len(alarms)} metric alarm(s)")

    records = [
        inventory_alarm_record(
            alarm=a,
            profile=profile,
            scanner_account_id=scanner_account_id,
            region=region,
        )
        for a in billing
    ]

    by_severity = Counter(r.severity for r in records)
    warn_removal = sum(1 for r in records if r.severity == "WARN")
    unmapped = sum(1 for r in records if not r.linked_account_id)
    per_account: dict[str, int] = Counter(
        r.linked_account_id or "UNMAPPED" for r in records
    )

    summary = [
        f"Scanned central profile {profile} (account {scanner_account_id}) in {region}.",
        (
            f"Billing alarms: {len(records)} "
            f"(CRIT={by_severity.get('CRIT', 0)}, WARN={by_severity.get('WARN', 0)}, "
            f"UNKNOWN={by_severity.get('UNKNOWN', 0)})."
        ),
        f"WARN removal candidates: {warn_removal}. Unmapped alarms: {unmapped}.",
        "CRIT thresholds are assessed in round 2: assess --from <inventory.json>.",
    ]

    return {
        "command": "inventory",
        "region": region,
        "profile": profile,
        "scanner_account_id": scanner_account_id,
        "alarm_count": len(records),
        "by_severity": dict(by_severity),
        "warn_removal_count": warn_removal,
        "unmapped_count": unmapped,
        "per_account_counts": dict(sorted(per_account.items())),
        "summary": summary,
        "alarms": records,
    }


def load_inventory(path: str) -> dict[str, Any]:
    p = Path(path)
    if not p.is_file():
        die(f"Inventory file not found: {path}", 1)
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        die(f"Invalid inventory JSON: {e}", 1)
    if data.get("command") != "inventory" or "alarms" not in data:
        die("Inventory JSON must be produced by: inventory -f json", 1)
    return data


def fetch_last_month_peak(
    cw: Any,
    *,
    linked_account_id: str,
    currency: str,
    service_name: str | None,
    start: datetime,
    end: datetime,
) -> float | None:
    dims = [
        {"Name": "Currency", "Value": currency},
        {"Name": "LinkedAccount", "Value": linked_account_id},
    ]
    if service_name:
        dims.append({"Name": "ServiceName", "Value": service_name})

    # Period 1 day; billing updates infrequently.
    period = 86400
    try:
        resp = cw.get_metric_data(
            StartTime=start,
            EndTime=end,
            MetricDataQueries=[
                {
                    "Id": "est",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/Billing",
                            "MetricName": "EstimatedCharges",
                            "Dimensions": dims,
                        },
                        "Period": period,
                        "Stat": "Maximum",
                    },
                    "ReturnData": True,
                }
            ],
        )
    except (ClientError, BotoCoreError) as e:
        log(f"GetMetricData failed for {linked_account_id}: {e}")
        return None

    values: list[float] = []
    for result in resp.get("MetricDataResults") or []:
        values.extend(float(v) for v in result.get("Values") or [])
    if not values:
        return None
    return max(values)


def iter_budgets(budgets: Any, account_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    next_token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"AccountId": account_id}
        if next_token:
            kwargs["NextToken"] = next_token
        resp = budgets.describe_budgets(**kwargs)
        out.extend(resp.get("Budgets") or [])
        next_token = resp.get("NextToken")
        if not next_token:
            break
    return out


def budget_limit_amount(budget: dict[str, Any]) -> float | None:
    limit = budget.get("BudgetLimit") or {}
    amount = limit.get("Amount")
    if amount is None:
        return None
    try:
        return float(amount)
    except (TypeError, ValueError):
        return None


def budget_linked_accounts(budget: dict[str, Any]) -> set[str]:
    accounts: set[str] = set()
    filters = budget.get("CostFilters") or {}
    for key in ("LinkedAccount", "LinkedAccountId"):
        for value in filters.get(key) or []:
            if isinstance(value, str) and ACCOUNT_ID_RE.fullmatch(value):
                accounts.add(value)
    name = budget.get("BudgetName") or ""
    for match in ACCOUNT_ID_RE.finditer(name):
        accounts.add(match.group(1))
    return accounts


def match_budget(
    budgets_list: list[dict[str, Any]],
    linked_account_id: str,
) -> tuple[str | None, float | None]:
    matches: list[tuple[str, float]] = []
    for budget in budgets_list:
        if linked_account_id not in budget_linked_accounts(budget):
            continue
        amount = budget_limit_amount(budget)
        if amount is None:
            continue
        matches.append((budget.get("BudgetName") or "", amount))
    if not matches:
        return None, None
    # Prefer the smallest matching cost budget as the intended account cap.
    matches.sort(key=lambda x: x[1])
    return matches[0]


def classify_crit(
    *,
    threshold: float | None,
    last_month_peak: float | None,
    budget_limit: float | None,
) -> tuple[str, list[str]]:
    notes: list[str] = []
    if threshold is None:
        return "NO_SPEND_SIGNAL", ["CRIT alarm has no threshold"]

    if last_month_peak is None and budget_limit is None:
        return "NO_SPEND_SIGNAL", ["No last-month EstimatedCharges datapoints and no matching Budget"]

    verdict: str | None = None

    if last_month_peak is not None and last_month_peak > 0:
        ratio = threshold / last_month_peak
        notes.append(f"threshold/last_month_peak={ratio:.2f}")
        if threshold <= 0.5 * last_month_peak:
            verdict = "CRIT_TOO_LOW"
            notes.append("Threshold ≤ 50% of last month peak — fires early most months")
        elif threshold <= 1.10 * last_month_peak:
            verdict = "CRIT_AT_BASELINE"
            notes.append("Threshold within ~0–10% of normal month — weak CRIT / month-end noise")
        elif threshold <= 1.30 * last_month_peak:
            verdict = "CRIT_OK_HEADROOM"
            notes.append("Threshold 10–30% above last month peak — reasonable overspend headroom")
        else:
            verdict = "CRIT_TOO_HIGH"
            notes.append("Threshold > 30% above last month peak — may never protect")
    elif budget_limit is not None and budget_limit > 0:
        # No metric; use budget bands as proxy for OK headroom.
        low = budget_limit * 1.10
        high = budget_limit * 1.20
        notes.append("Using Budget only (no last-month peak)")
        if threshold <= 0.5 * budget_limit:
            verdict = "CRIT_TOO_LOW"
        elif threshold < low:
            verdict = "CRIT_AT_BASELINE"
        elif threshold <= high:
            verdict = "CRIT_OK_HEADROOM"
        else:
            verdict = "CRIT_TOO_HIGH"

    if (
        budget_limit is not None
        and budget_limit > 0
        and threshold is not None
        and abs(threshold - budget_limit) / budget_limit > 0.25
    ):
        notes.append(
            f"CloudWatch CRIT ({threshold}) drifts >25% from Budget limit ({budget_limit})"
        )
        if verdict in {None, "CRIT_OK_HEADROOM"}:
            return "CRIT_VS_BUDGET_DRIFT", notes
        notes.append("Also flagged CRIT_VS_BUDGET_DRIFT condition")

    if budget_limit is not None and last_month_peak is not None:
        suggested = max(budget_limit * 1.1, last_month_peak * 1.1)
        notes.append(
            f"Suggested CRIT band ≈ 110–120% of expected month "
            f"(~{suggested:.0f} using max(budget×1.1, peak×1.1))"
        )

    return verdict or "NO_SPEND_SIGNAL", notes


def run_assess(profile: str, region: str, inventory: dict[str, Any]) -> dict[str, Any]:
    log(f"assess | profile={profile} region={region}")
    crit_alarms = [
        a
        for a in inventory.get("alarms") or []
        if (a.get("severity") == "CRIT")
    ]
    log(f"CRIT alarms in inventory: {len(crit_alarms)}")

    try:
        session = make_session(profile, region)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        scanner_account_id = identity["Account"]
        log(f"Scanner account: {scanner_account_id}")
        cw = session.client("cloudwatch", region_name=region)
        budgets_client = session.client("budgets", region_name=BILLING_REGION)
        budgets_list = iter_budgets(budgets_client, scanner_account_id)
        log(f"Budgets visible in central account: {len(budgets_list)}")
    except (ClientError, BotoCoreError) as e:
        die(f"AWS error during assess: {e}", 2)

    start, end = previous_calendar_month_window()
    log(
        f"Spend window: {start.date()} → {end.date()} "
        f"({calendar.month_name[start.month]} {start.year})"
    )

    # Cache peaks by (account, currency, service)
    peak_cache: dict[tuple[str, str, str | None], float | None] = {}
    rows: list[AssessRow] = []

    for alarm in crit_alarms:
        linked = alarm.get("linked_account_id")
        currency = alarm.get("currency") or "USD"
        service_name = alarm.get("service_name")
        threshold = alarm.get("threshold")
        if isinstance(threshold, str):
            try:
                threshold = float(threshold)
            except ValueError:
                threshold = None

        last_month_peak: float | None = None
        budget_name: str | None = None
        budget_limit: float | None = None

        if linked:
            cache_key = (linked, currency, service_name)
            if cache_key not in peak_cache:
                peak_cache[cache_key] = fetch_last_month_peak(
                    cw,
                    linked_account_id=linked,
                    currency=currency,
                    service_name=service_name,
                    start=start,
                    end=end,
                )
            last_month_peak = peak_cache[cache_key]
            budget_name, budget_limit = match_budget(budgets_list, linked)
            verdict, notes = classify_crit(
                threshold=threshold,
                last_month_peak=last_month_peak,
                budget_limit=budget_limit,
            )
        else:
            verdict = "UNMAPPED_ACCOUNT"
            notes = ["CRIT alarm has no linked account — cannot assess spend/Budget"]

        rows.append(
            AssessRow(
                alarm_name=alarm.get("alarm_name") or "",
                linked_account_id=linked,
                threshold=threshold,
                service_name=service_name,
                currency=currency,
                last_month_peak=last_month_peak,
                budget_limit=budget_limit,
                budget_name=budget_name,
                verdict=verdict,
                notes=notes,
            )
        )

    by_verdict = Counter(r.verdict for r in rows)
    summary = [
        f"Assessed {len(rows)} CRIT alarm(s) via profile {profile} (account {scanner_account_id}).",
        f"Spend basis: max EstimatedCharges for previous calendar month ({start.strftime('%Y-%m')}).",
        f"Verdicts: {', '.join(f'{k}={v}' for k, v in sorted(by_verdict.items())) or 'none'}.",
        (
            "Guidance: for ~$9–10k monthly spend, CRIT ≈ 110–120% of expected month "
            "(or budget×1.1–1.2) — not $10/$1k, and not exactly the normal month total."
        ),
    ]

    return {
        "command": "assess",
        "region": region,
        "profile": profile,
        "scanner_account_id": scanner_account_id,
        "spend_month": start.strftime("%Y-%m"),
        "inventory_alarm_count": inventory.get("alarm_count"),
        "crit_count": len(rows),
        "by_verdict": dict(by_verdict),
        "summary": summary,
        "assessments": rows,
    }


def emit_inventory_table(ctx: dict[str, Any]) -> None:
    print("Billing Alarms Inventory (WARN / CRIT)")
    print("=" * 38)
    for line in ctx["summary"]:
        print(f" - {line}")
    print()
    print("Per linked account:")
    for account, count in (ctx.get("per_account_counts") or {}).items():
        print(f" - {account}: {count}")
    print()
    if not ctx["alarms"]:
        print("No billing alarms found.")
        return
    for rec in ctx["alarms"]:
        findings = (
            "; ".join(f"[{f.severity}] {f.code}: {f.detail}" for f in rec.findings)
            if rec.findings
            else "(none)"
        )
        print(f"Alarm: {rec.alarm_name}")
        print(f"  Severity: {rec.severity} | State: {rec.state}")
        print(f"  LinkedAccount: {rec.linked_account_id or 'UNMAPPED'}")
        print(f"  Threshold: {rec.threshold} | Metric: {rec.namespace}/{rec.metric_name}")
        print(f"  ServiceName: {rec.service_name or 'n/a'} | Currency: {rec.currency or 'n/a'}")
        print(f"  Findings: {findings}")
        print()


def emit_inventory_markdown(ctx: dict[str, Any]) -> None:
    print("# Billing Alarms Inventory (WARN / CRIT)")
    print()
    for line in ctx["summary"]:
        print(f"- {line}")
    print()
    print("| Severity | Linked account | Alarm | Threshold | State | Findings |")
    print("|----------|----------------|-------|-----------|-------|----------|")
    for rec in ctx["alarms"]:
        findings = (
            "<br>".join(f"`{f.code}`" for f in rec.findings) if rec.findings else "_none_"
        )
        print(
            f"| {rec.severity} | `{rec.linked_account_id or 'UNMAPPED'}` | "
            f"`{rec.alarm_name}` | {rec.threshold} | {rec.state} | {findings} |"
        )


def emit_assess_table(ctx: dict[str, Any]) -> None:
    print("Billing CRIT Threshold Assessment")
    print("=" * 34)
    for line in ctx["summary"]:
        print(f" - {line}")
    print()
    if not ctx["assessments"]:
        print("No CRIT alarms to assess.")
        return
    for row in ctx["assessments"]:
        print(f"Alarm: {row.alarm_name}")
        print(f"  Account: {row.linked_account_id or 'UNMAPPED'}")
        print(
            f"  CRIT threshold: {row.threshold} | "
            f"last_month_peak: {row.last_month_peak} | "
            f"budget: {row.budget_limit} ({row.budget_name or 'n/a'})"
        )
        print(f"  Verdict: {row.verdict}")
        if row.notes:
            for note in row.notes:
                print(f"   - {note}")
        print()


def emit_assess_markdown(ctx: dict[str, Any]) -> None:
    print("# Billing CRIT Threshold Assessment")
    print()
    for line in ctx["summary"]:
        print(f"- {line}")
    print()
    print(
        "| Account | Alarm | CRIT threshold | Last month peak | Budget | Verdict | Notes |"
    )
    print(
        "|---------|-------|----------------|-----------------|--------|---------|-------|"
    )
    for row in ctx["assessments"]:
        notes = "<br>".join(row.notes) if row.notes else "_none_"
        print(
            f"| `{row.linked_account_id or 'UNMAPPED'}` | `{row.alarm_name}` | "
            f"{row.threshold} | {row.last_month_peak} | "
            f"{row.budget_limit} | `{row.verdict}` | {notes} |"
        )


def emit_json(ctx: dict[str, Any]) -> None:
    payload = dict(ctx)
    if "alarms" in payload:
        payload["alarms"] = [
            {
                **{k: v for k, v in asdict(a).items() if k != "findings"},
                "findings": [asdict(f) for f in a.findings],
            }
            for a in payload["alarms"]
        ]
    if "assessments" in payload:
        payload["assessments"] = [asdict(a) for a in payload["assessments"]]
    print(json.dumps(payload, indent=2))


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as e:
        return int(e.code) if isinstance(e.code, int) else 1

    profile = require_profile(args.profile)
    region = resolve_region(args.region)
    if region != BILLING_REGION:
        log(
            f"Warning: billing metrics are only published in {BILLING_REGION}; "
            f"using {region} as requested"
        )

    if args.command == "inventory":
        ctx = run_inventory(profile, region)
        log("Done.")
        print("", file=sys.stderr)
        if args.format == "table":
            emit_inventory_table(ctx)
        elif args.format == "markdown":
            emit_inventory_markdown(ctx)
        else:
            emit_json(ctx)
        return 0

    inventory = load_inventory(args.from_path)
    ctx = run_assess(profile, region, inventory)
    log("Done.")
    print("", file=sys.stderr)
    if args.format == "table":
        emit_assess_table(ctx)
    elif args.format == "markdown":
        emit_assess_markdown(ctx)
    else:
        emit_json(ctx)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
