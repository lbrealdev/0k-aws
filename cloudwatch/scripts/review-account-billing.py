#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.34",
#   "prettytable>=3.10",
# ]
# ///
"""Review one member account: master CloudWatch/Budgets + target Cost Explorer spend.

Plain-text stdout report with PrettyTable sections and NORMAL/ABNORMAL verdict.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from statistics import median
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from prettytable import PrettyTable

SCRIPT_NAME = "review-account-billing.py"
BILLING_REGION = "us-east-1"
CE_REGION = "us-east-1"
ACCOUNT_ID_RE = re.compile(r"(?<!\d)(\d{12})(?!\d)")


def log(msg: str) -> None:
    print(f"-> {msg}", file=sys.stderr)


def die(msg: str, code: int) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_region(cli_region: str | None) -> str:
    if cli_region:
        return cli_region
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or BILLING_REGION


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Review one member account: CloudWatch alarms + Budgets from the master "
            "(payer) profile, and Cost Explorer spend from the target profile. "
            "Prints a plain-text NORMAL/ABNORMAL report."
        ),
    )
    p.add_argument("-p", "--profile", required=True, help="Master (payer) SSO/CLI profile")
    p.add_argument(
        "-t",
        "--target-profile",
        required=True,
        help="Target member account SSO/CLI profile",
    )
    p.add_argument("-r", "--region", default=None, help="Region for CloudWatch (default us-east-1)")
    p.add_argument(
        "--months",
        type=int,
        default=6,
        help="Complete calendar months of CE history (default 6)",
    )
    p.add_argument(
        "--budget-name",
        default=None,
        help="Optional substring filter on budget name after account matching",
    )
    args = p.parse_args(argv)
    if args.months < 1:
        die("--months must be >= 1", 1)
    return args


def make_session(profile: str, region: str) -> Any:
    return boto3.Session(profile_name=profile, region_name=region)


def caller_identity(session: Any) -> dict[str, str]:
    sts = session.client("sts")
    ident = sts.get_caller_identity()
    return {"account_id": ident["Account"], "arn": ident.get("Arn") or ""}


def dimensions_map(alarm: dict[str, Any]) -> dict[str, str]:
    return {d["Name"]: d["Value"] for d in alarm.get("Dimensions") or [] if "Name" in d and "Value" in d}


def is_billing_alarm(alarm: dict[str, Any]) -> bool:
    return alarm.get("Namespace") == "AWS/Billing" or alarm.get("MetricName") == "EstimatedCharges"


def parse_severity(alarm_name: str) -> str:
    upper = alarm_name.upper()
    has_crit = re.search(r"(?<![A-Z])CRIT(?![A-Z])", upper) is not None
    has_warn = re.search(r"(?<![A-Z])WARN(?![A-Z])", upper) is not None
    if has_crit and not has_warn:
        return "CRIT"
    if has_warn and not has_crit:
        return "WARN"
    if has_crit and has_warn:
        return "CRIT"
    return "UNKNOWN"


def resolve_linked_account(alarm_name: str, dims: dict[str, str]) -> str | None:
    if dims.get("LinkedAccount"):
        return dims["LinkedAccount"]
    match = ACCOUNT_ID_RE.search(alarm_name)
    return match.group(1) if match else None


def list_metric_alarms(cw: Any) -> list[dict[str, Any]]:
    alarms: list[dict[str, Any]] = []
    paginator = cw.get_paginator("describe_alarms")
    for page in paginator.paginate(AlarmTypes=["MetricAlarm"]):
        alarms.extend(page.get("MetricAlarms") or [])
    return alarms


@dataclass
class AlarmRow:
    name: str
    severity: str
    state: str
    threshold: float | None
    linked_account_id: str | None
    currency: str | None
    service_name: str | None


def collect_target_alarms(cw: Any, target_account_id: str) -> list[AlarmRow]:
    rows: list[AlarmRow] = []
    for alarm in list_metric_alarms(cw):
        if not is_billing_alarm(alarm):
            continue
        dims = dimensions_map(alarm)
        linked = resolve_linked_account(alarm.get("AlarmName") or "", dims)
        if linked != target_account_id:
            continue
        threshold = alarm.get("Threshold")
        rows.append(
            AlarmRow(
                name=alarm.get("AlarmName") or "",
                severity=parse_severity(alarm.get("AlarmName") or ""),
                state=alarm.get("StateValue") or "",
                threshold=float(threshold) if threshold is not None else None,
                linked_account_id=linked,
                currency=dims.get("Currency"),
                service_name=dims.get("ServiceName"),
            )
        )
    rows.sort(key=lambda r: r.name)
    return rows


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


def budget_limit_amount(budget: dict[str, Any]) -> float | None:
    limit = budget.get("BudgetLimit") or {}
    amount = limit.get("Amount")
    if amount is None:
        return None
    try:
        return float(amount)
    except (TypeError, ValueError):
        return None


def calculated_spend_field(budget: dict[str, Any], which: str) -> float | None:
    calc = budget.get("CalculatedSpend") or {}
    block = calc.get(which) or {}
    amount = block.get("Amount")
    if amount is None:
        return None
    try:
        return float(amount)
    except (TypeError, ValueError):
        return None


@dataclass
class BudgetRow:
    name: str
    limit: float | None
    unit: str | None
    time_unit: str | None
    budget_type: str | None
    actual: float | None
    forecast: float | None


def collect_target_budgets(
    budgets_client: Any,
    master_account_id: str,
    target_account_id: str,
    budget_name_substr: str | None,
) -> list[BudgetRow]:
    rows: list[BudgetRow] = []
    for budget in iter_budgets(budgets_client, master_account_id):
        if target_account_id not in budget_linked_accounts(budget):
            continue
        name = budget.get("BudgetName") or ""
        if budget_name_substr and budget_name_substr not in name:
            continue
        limit_block = budget.get("BudgetLimit") or {}
        rows.append(
            BudgetRow(
                name=name,
                limit=budget_limit_amount(budget),
                unit=limit_block.get("Unit"),
                time_unit=budget.get("TimeUnit"),
                budget_type=budget.get("BudgetType"),
                actual=calculated_spend_field(budget, "ActualSpend"),
                forecast=calculated_spend_field(budget, "ForecastedSpend"),
            )
        )
    rows.sort(key=lambda r: (r.limit is None, r.limit or 0.0, r.name))
    return rows


def month_start(d: date) -> date:
    return date(d.year, d.month, 1)


def add_months(d: date, months: int) -> date:
    year = d.year + (d.month - 1 + months) // 12
    month = (d.month - 1 + months) % 12 + 1
    return date(year, month, 1)


def complete_months_window(n: int, today: date | None = None) -> tuple[date, date]:
    """Return [start, end) covering the last n complete calendar months."""
    today = today or datetime.now(timezone.utc).date()
    end = month_start(today)  # first day of current month
    start = add_months(end, -n)
    return start, end


def fmt_ce_day(d: date) -> str:
    return d.isoformat()


def get_cost_and_usage(
    ce: Any,
    *,
    start: date,
    end: date,
    granularity: str,
) -> list[dict[str, Any]]:
    """Return TimePeriod results; end is exclusive per CE API."""
    results: list[dict[str, Any]] = []
    next_token: str | None = None
    while True:
        kwargs: dict[str, Any] = {
            "TimePeriod": {"Start": fmt_ce_day(start), "End": fmt_ce_day(end)},
            "Granularity": granularity,
            "Metrics": ["UnblendedCost"],
        }
        if next_token:
            kwargs["NextPageToken"] = next_token
        resp = ce.get_cost_and_usage(**kwargs)
        results.extend(resp.get("ResultsByTime") or [])
        next_token = resp.get("NextPageToken")
        if not next_token:
            break
    return results


def parse_unblended(result: dict[str, Any]) -> float:
    total = (result.get("Total") or {}).get("UnblendedCost") or {}
    amount = total.get("Amount")
    if amount is None:
        return 0.0
    try:
        return float(amount)
    except (TypeError, ValueError):
        return 0.0


@dataclass
class MonthSpend:
    month: str  # YYYY-MM
    amount: float


def fetch_monthly_spend(ce: Any, months: int) -> list[MonthSpend]:
    start, end = complete_months_window(months)
    log(f"CE monthly window: {start} -> {end} (exclusive end)")
    results = get_cost_and_usage(ce, start=start, end=end, granularity="MONTHLY")
    rows: list[MonthSpend] = []
    for item in results:
        period = item.get("TimePeriod") or {}
        start_s = period.get("Start") or ""
        month_key = start_s[:7] if len(start_s) >= 7 else start_s
        amount = parse_unblended(item)
        # Skip empty Estimated months with zero and no data flag if desired;
        # keep zeros that represent real zero spend.
        if item.get("Estimated") and amount == 0.0:
            continue
        rows.append(MonthSpend(month=month_key, amount=amount))
    rows.sort(key=lambda r: r.month)
    return rows


def fetch_mtd_spend(ce: Any, today: date | None = None) -> float:
    today = today or datetime.now(timezone.utc).date()
    start = month_start(today)
    # CE End is exclusive; use tomorrow so today is included.
    end = today + timedelta(days=1)
    log(f"CE MTD window: {start} -> {end} (exclusive end)")
    results = get_cost_and_usage(ce, start=start, end=end, granularity="DAILY")
    return sum(parse_unblended(item) for item in results)


def sum_last_n(months: list[MonthSpend], n: int) -> float | None:
    if not months:
        return None
    slice_ = months[-n:] if len(months) >= n else months
    if not slice_:
        return None
    return sum(m.amount for m in slice_)


def classify_spend(months: list[MonthSpend]) -> tuple[str, str]:
    """Return (verdict, reason) using 0.5x-1.5x median band."""
    amounts = [m.amount for m in months if m.amount is not None]
    if len(amounts) < 2:
        return "INSUFFICIENT_DATA", "Fewer than 2 complete months of Cost Explorer data"

    med = median(amounts)
    if med <= 0:
        if any(a > 0 for a in amounts):
            return "ABNORMAL", "Median monthly spend is 0 but some months have spend > 0"
        return "NORMAL", "All complete months are 0 (or negligible)"

    high = [m for m in months if m.amount > 1.5 * med]
    low = [m for m in months if m.amount < 0.5 * med]
    if high or low:
        parts: list[str] = []
        if high:
            parts.append(
                "high: " + ", ".join(f"{m.month}={m.amount:.2f}" for m in high) + f" (>1.5x median {med:.2f})"
            )
        if low:
            parts.append(
                "low: " + ", ".join(f"{m.month}={m.amount:.2f}" for m in low) + f" (<0.5x median {med:.2f})"
            )
        return "ABNORMAL", "; ".join(parts)

    return "NORMAL", f"All months within 0.5x-1.5x of median {med:.2f}"


def fmt_money(v: float | None) -> str:
    if v is None:
        return "n/a"
    return f"{v:,.2f}"


def pct(part: float | None, whole: float | None) -> str:
    if part is None or whole is None or whole <= 0:
        return "n/a"
    return f"{(part / whole) * 100:.1f}%"


def render_report(
    *,
    master_profile: str,
    master_account_id: str,
    target_profile: str,
    target_account_id: str,
    region: str,
    alarms: list[AlarmRow],
    budgets: list[BudgetRow],
    months: list[MonthSpend],
    mtd: float,
    months_requested: int,
    verdict: str,
    reason: str,
) -> str:
    lines: list[str] = []
    lines.append("Account billing review")
    lines.append("=" * 22)
    lines.append(f"Master profile : {master_profile} (account {master_account_id})")
    lines.append(f"Target profile : {target_profile} (account {target_account_id})")
    lines.append(f"CloudWatch region: {region}")
    lines.append("")

    lines.append("CloudWatch billing alarms (master, for target account)")
    if not alarms:
        lines.append("  (none found)")
    else:
        t = PrettyTable()
        t.field_names = ["Name", "Severity", "State", "Threshold", "Currency", "ServiceName"]
        t.align = "l"
        for a in alarms:
            t.add_row(
                [
                    a.name,
                    a.severity,
                    a.state,
                    fmt_money(a.threshold),
                    a.currency or "n/a",
                    a.service_name or "n/a",
                ]
            )
        lines.append(str(t))
    lines.append("")

    lines.append("Budgets (master, for target account)")
    if not budgets:
        lines.append("  (none found)")
    else:
        t = PrettyTable()
        t.field_names = [
            "Name",
            "Limit",
            "Unit",
            "TimeUnit",
            "Type",
            "Actual",
            "Forecast",
            "MTD%Limit",
        ]
        t.align = "l"
        for b in budgets:
            t.add_row(
                [
                    b.name,
                    fmt_money(b.limit),
                    b.unit or "n/a",
                    b.time_unit or "n/a",
                    b.budget_type or "n/a",
                    fmt_money(b.actual),
                    fmt_money(b.forecast),
                    pct(mtd, b.limit),
                ]
            )
        lines.append(str(t))
    lines.append("")

    lines.append(f"Spend (Cost Explorer UnblendedCost, target account)")
    lines.append(f"MTD (1st of month through today): {fmt_money(mtd)}")
    last1 = sum_last_n(months, 1)
    last3 = sum_last_n(months, min(3, len(months))) if months else None
    last6 = sum_last_n(months, min(6, len(months))) if months else None
    lines.append(
        f"Sums of complete months: last1={fmt_money(last1)} "
        f"last3={fmt_money(last3)} last{min(months_requested, max(len(months), 1))}="
        f"{fmt_money(sum_last_n(months, months_requested) if months else None)}"
    )
    if not months:
        lines.append("  (no complete-month CE data)")
    else:
        t = PrettyTable()
        t.field_names = ["Month", "UnblendedCost"]
        t.align = "l"
        for m in months:
            t.add_row([m.month, fmt_money(m.amount)])
        # Also show last6 sum row for clarity when requested window differs
        if last6 is not None and months_requested >= 6:
            t.add_row([f"(sum last {min(6, len(months))})", fmt_money(last6)])
        lines.append(str(t))
    lines.append("")

    lines.append(f"Verdict: {verdict}")
    lines.append(f"Reason : {reason}")
    if budgets:
        smallest = min((b.limit for b in budgets if b.limit is not None), default=None)
        if smallest is not None:
            lines.append(
                f"Note   : MTD is {pct(mtd, smallest)} of smallest matched budget limit "
                f"({fmt_money(smallest)})"
            )
    lines.append("")
    return "\n".join(lines)


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

    try:
        master_session = make_session(args.profile, region)
        target_session = make_session(args.target_profile, region)
        master_id = caller_identity(master_session)
        target_id = caller_identity(target_session)
    except (ClientError, BotoCoreError) as e:
        die(f"AWS error resolving identities: {e}", 2)

    if master_id["account_id"] == target_id["account_id"]:
        die(
            "Master and target profiles resolve to the same account "
            f"({master_id['account_id']}); pass a member --target-profile",
            1,
        )

    log(f"Master: {args.profile} / {master_id['account_id']}")
    log(f"Target: {args.target_profile} / {target_id['account_id']}")

    try:
        cw = master_session.client("cloudwatch", region_name=region)
        budgets_client = master_session.client("budgets", region_name=BILLING_REGION)
        ce = target_session.client("ce", region_name=CE_REGION)

        log("Fetching CloudWatch billing alarms from master...")
        alarms = collect_target_alarms(cw, target_id["account_id"])
        log(f"Matched alarms: {len(alarms)}")

        log("Fetching Budgets from master...")
        budgets = collect_target_budgets(
            budgets_client,
            master_id["account_id"],
            target_id["account_id"],
            args.budget_name,
        )
        log(f"Matched budgets: {len(budgets)}")

        log("Fetching Cost Explorer spend from target...")
        months = fetch_monthly_spend(ce, args.months)
        mtd = fetch_mtd_spend(ce)
        log(f"Complete months: {len(months)}; MTD={mtd:.2f}")
    except (ClientError, BotoCoreError) as e:
        die(f"AWS error during review: {e}", 2)

    verdict, reason = classify_spend(months)
    report = render_report(
        master_profile=args.profile,
        master_account_id=master_id["account_id"],
        target_profile=args.target_profile,
        target_account_id=target_id["account_id"],
        region=region,
        alarms=alarms,
        budgets=budgets,
        months=months,
        mtd=mtd,
        months_requested=args.months,
        verdict=verdict,
        reason=reason,
    )
    log("Done.")
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
