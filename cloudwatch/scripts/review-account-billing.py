#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3>=1.34",
# ]
# ///
"""Review one member account: hub CloudWatch/Budgets + member Cost Explorer spend.

Plain-text stdout report with NORMAL/ABNORMAL/INSUFFICIENT_DATA verdict.

Exit codes: 0 completed, 1 usage, 2 AWS error.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import threading
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from statistics import median
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

SCRIPT_NAME = "review-account-billing.py"
BILLING_REGION = "us-east-1"
ACCOUNT_ID_RE = re.compile(r"(?<!\d)(\d{12})(?!\d)")
ENV_CREDENTIAL_VARS = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)


def die(msg: str, code: int) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


class Spinner:
    """One-line stderr spinner. TTY only; no-op when piped."""

    FRAMES = ("|", "/", "-", "\\")

    def __init__(self) -> None:
        self.enabled = sys.stderr.isatty()
        self._msg = ""
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self, msg: str) -> None:
        if not self.enabled:
            return
        with self._lock:
            self._msg = msg
            if self._thread is None or not self._thread.is_alive():
                self._stop.clear()
                self._thread = threading.Thread(target=self._run, daemon=True)
                self._thread.start()

    def _run(self) -> None:
        i = 0
        while True:
            with self._lock:
                msg = self._msg
            frame = self.FRAMES[i % len(self.FRAMES)]
            sys.stderr.write(f"\r\033[2K {frame} {msg}")
            sys.stderr.flush()
            i += 1
            if self._stop.wait(0.08):
                break

    def stop(self) -> None:
        if not self.enabled or self._thread is None:
            return
        self._stop.set()
        self._thread.join(timeout=0.5)
        self._thread = None
        sys.stderr.write("\r\033[2K")
        sys.stderr.flush()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Review one member account: CloudWatch alarms + Budgets from the hub "
            "(payer) SSO profile, and Cost Explorer spend from the member SSO profile.\n"
            "\n"
            "Auth: named SSO profiles only (--hub and --account). Does not use "
            "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN, and "
            "those env vars must be unset (boto3 would let them override the "
            "profiles). Run `aws sso login` for each profile first.\n"
            "\n"
            "Billing APIs always use us-east-1. Prints a plain-text NORMAL/ABNORMAL report."
        ),
    )
    p.add_argument(
        "--hub",
        required=True,
        help="Hub (payer) SSO profile: Budgets + CloudWatch billing alarms",
    )
    p.add_argument(
        "-a",
        "--account",
        required=True,
        help="Member account SSO profile (linked/target account, not an account id)",
    )
    p.add_argument(
        "--months",
        type=int,
        default=6,
        help="Complete calendar months of CE history (default 6)",
    )
    p.add_argument(
        "--budget",
        default=None,
        help="Optional substring filter on budget name after account matching",
    )
    p.add_argument(
        "--color",
        choices=("auto", "always", "never"),
        default="auto",
        help="ANSI color: auto (TTY only), always, or never (default auto)",
    )
    args = p.parse_args(argv)
    if args.months < 1:
        die("--months must be >= 1", 1)
    return args


def reject_env_credentials() -> None:
    present = [name for name in ENV_CREDENTIAL_VARS if os.environ.get(name)]
    if present:
        die(
            "named SSO profiles only (--hub / --account); unset "
            + ", ".join(present)
            + " (env credentials override profiles and cannot select two accounts)",
            1,
        )


def make_session(profile: str) -> Any:
    return boto3.Session(profile_name=profile, region_name=BILLING_REGION)


def caller_identity(session: Any) -> dict[str, str]:
    sts = session.client("sts")
    ident = sts.get_caller_identity()
    return {"account_id": ident["Account"], "arn": ident.get("Arn") or ""}


def account_alias(session: Any) -> str | None:
    iam = session.client("iam")
    try:
        aliases = iam.list_account_aliases().get("AccountAliases") or []
    except (ClientError, BotoCoreError):
        return None
    alias = aliases[0] if aliases else None
    if not alias or alias == "None":
        return None
    return alias


def account_label(alias: str | None, account_id: str) -> str:
    if alias:
        return f"{alias} ({account_id})"
    return account_id


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
    hub_account_id: str,
    target_account_id: str,
    budget_name_substr: str | None,
) -> list[BudgetRow]:
    rows: list[BudgetRow] = []
    for budget in iter_budgets(budgets_client, hub_account_id):
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
    end = month_start(today)
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
    results = get_cost_and_usage(ce, start=start, end=end, granularity="MONTHLY")
    rows: list[MonthSpend] = []
    for item in results:
        period = item.get("TimePeriod") or {}
        start_s = period.get("Start") or ""
        month_key = start_s[:7] if len(start_s) >= 7 else start_s
        amount = parse_unblended(item)
        if item.get("Estimated") and amount == 0.0:
            continue
        rows.append(MonthSpend(month=month_key, amount=amount))
    rows.sort(key=lambda r: r.month)
    return rows


def fetch_mtd_spend(ce: Any, today: date | None = None) -> float:
    today = today or datetime.now(timezone.utc).date()
    start = month_start(today)
    end = today + timedelta(days=1)
    results = get_cost_and_usage(ce, start=start, end=end, granularity="DAILY")
    return sum(parse_unblended(item) for item in results)


def spend_median(months: list[MonthSpend]) -> float | None:
    amounts = [m.amount for m in months]
    if len(amounts) < 2:
        return None
    return median(amounts)


def band_outliers(months: list[MonthSpend], med: float) -> tuple[list[MonthSpend], list[MonthSpend]]:
    if med <= 0:
        return [], []
    high = [m for m in months if m.amount > 1.5 * med]
    low = [m for m in months if m.amount < 0.5 * med]
    return high, low


def classify_spend(months: list[MonthSpend]) -> str:
    """Verdict using 0.5x-1.5x median band on complete months."""
    med = spend_median(months)
    if med is None:
        return "INSUFFICIENT_DATA"
    if med <= 0:
        if any(m.amount > 0 for m in months):
            return "ABNORMAL"
        return "NORMAL"
    high, low = band_outliers(months, med)
    if high or low:
        return "ABNORMAL"
    return "NORMAL"


ANSI_RESET = "\033[0m"
ANSI_GREEN = "\033[32m"
ANSI_RED = "\033[31m"
ANSI_YELLOW = "\033[33m"

VERDICT_COLOR = {
    "NORMAL": ANSI_GREEN,
    "ABNORMAL": ANSI_RED,
    "INSUFFICIENT_DATA": ANSI_YELLOW,
}
STATUS_COLOR = {
    "OK": ANSI_GREEN,
    "WATCH": ANSI_YELLOW,
    "BREACH": ANSI_RED,
}
STATE_COLOR = {
    "OK": ANSI_GREEN,
    "ALARM": ANSI_RED,
    "NODATA": ANSI_YELLOW,
}
FLAG_COLOR = {
    "HIGH": ANSI_RED,
    "LOW": ANSI_YELLOW,
}
ALARM_STATE_LABEL = {
    "INSUFFICIENT_DATA": "NODATA",
}


def color_enabled(mode: str) -> bool:
    if mode == "always":
        return True
    if mode == "never":
        return False
    return sys.stdout.isatty()


def paint(text: str, color: str | None, enabled: bool) -> str:
    if not enabled or not color:
        return text
    return f"{color}{text}{ANSI_RESET}"


def fmt_money(v: float | None) -> str:
    if v is None:
        return "n/a"
    return f"{v:,.2f}"


def money_display(v: float | None) -> str:
    if v is None:
        return "n/a"
    return f"${fmt_money(v)}"


def aligned_fields(pairs: list[tuple[str, str]], indent: str = "") -> list[str]:
    if not pairs:
        return []
    width = max(len(k) for k, _ in pairs)
    return [f"{indent}{k.ljust(width)}: {v}" for k, v in pairs]


def month_abbr(yyyy_mm: str) -> str:
    try:
        return datetime.strptime(yyyy_mm, "%Y-%m").strftime("%b")
    except ValueError:
        return yyyy_mm


def mtd_span_label(today: date) -> str:
    return f"{today.strftime('%b')} 1-{today.day}"


def monthly_limit_of(b: BudgetRow) -> tuple[float | None, str | None]:
    if b.limit is None:
        return None, b.time_unit
    tu = (b.time_unit or "").upper()
    if tu == "QUARTERLY":
        return b.limit / 3.0, b.time_unit
    if tu == "ANNUALLY":
        return b.limit / 12.0, b.time_unit
    return b.limit, b.time_unit


def budget_usage_amount(b: BudgetRow, mtd: float) -> float:
    actual_val = b.actual if b.actual is not None else mtd
    if b.forecast is not None:
        return max(actual_val, b.forecast)
    return actual_val


def budget_status(b: BudgetRow, mtd: float) -> str:
    monthly, _ = monthly_limit_of(b)
    if monthly is None or monthly <= 0:
        return "n/a"
    ratio = budget_usage_amount(b, mtd) / monthly
    if ratio > 1.0:
        return "BREACH"
    if ratio >= 0.8:
        return "WATCH"
    return "OK"


def complete_month_sum(months: list[MonthSpend], n: int) -> float | None:
    if len(months) < n:
        return None
    return sum(m.amount for m in months[-n:])


def window_sums(months: list[MonthSpend], months_requested: int) -> tuple[str, str] | None:
    windows: list[int] = [1, 3]
    if months_requested not in windows:
        windows.append(months_requested)
    labels: list[str] = []
    values: list[str] = []
    for n in windows:
        total = complete_month_sum(months, n)
        if total is None:
            continue
        labels.append(f"{n}M")
        values.append(money_display(total))
    if not values:
        return None
    return " / ".join(labels), " / ".join(values)


def month_flag(amount: float, med: float | None) -> str | None:
    if med is None or med <= 0:
        return None
    if amount > 1.5 * med:
        return "HIGH"
    if amount < 0.5 * med:
        return "LOW"
    return None


def alarm_state_label(state: str) -> str:
    return ALARM_STATE_LABEL.get(state, state or "n/a")


def limit_label(b: BudgetRow) -> str:
    monthly, tu = monthly_limit_of(b)
    tu_u = (tu or "").upper()
    if b.limit is None:
        return "n/a"
    shown = money_display(b.limit)
    if tu_u == "QUARTERLY":
        return f"{shown}/qtr ({money_display(monthly)}/mo)"
    if tu_u == "ANNUALLY":
        return f"{shown}/yr ({money_display(monthly)}/mo)"
    if tu_u == "MONTHLY" or not tu_u:
        return f"{shown}/mo"
    return f"{shown}/{tu_u.lower()}"


def verdict_detail_lines(months: list[MonthSpend]) -> list[str]:
    med = spend_median(months)
    if med is None:
        return ["Fewer than 2 complete months of Cost Explorer data"]
    if med <= 0:
        if any(m.amount > 0 for m in months):
            return ["Median monthly spend is 0 but some months have spend > 0"]
        return ["All complete months are 0 (or negligible)"]
    high, low = band_outliers(months, med)
    if not high and not low:
        return [f"All months within 0.5x-1.5x of median {money_display(med)}"]
    lines: list[str] = []
    for m in high:
        ratio = m.amount / med
        lines.append(f"{month_abbr(m.month)} {money_display(m.amount)} is {ratio:.1f}x median {money_display(med)}")
    for m in low:
        ratio = m.amount / med
        lines.append(f"{month_abbr(m.month)} {money_display(m.amount)} is {ratio:.1f}x median {money_display(med)}")
    return lines


def render_alarms(alarms: list[AlarmRow], color: bool) -> list[str]:
    lines = [f"ALARMS ({len(alarms)})  hub -> target"]
    if not alarms:
        lines.append("  (none)")
        return lines
    for a in alarms:
        state = alarm_state_label(a.state)
        bits = [
            f"{(a.severity or 'n/a'):<4}",
            paint(f"{state:<6}", STATE_COLOR.get(state), color),
            f"{money_display(a.threshold):>12}",
        ]
        extra = []
        if a.currency:
            extra.append(a.currency)
        if a.service_name:
            extra.append(a.service_name)
        meta = f"  {'  '.join(bits)}"
        if extra:
            meta += "  " + "  ".join(extra)
        lines.append(meta)
        lines.append(f"    {a.name}")
    return lines


def render_budgets(budgets: list[BudgetRow], mtd: float, color: bool) -> list[str]:
    lines = [f"BUDGETS ({len(budgets)})  hub -> target"]
    if not budgets:
        lines.append("  (none)")
        return lines
    for b in budgets:
        monthly, _ = monthly_limit_of(b)
        status = budget_status(b, mtd)
        if monthly is None or monthly <= 0:
            used = "used n/a"
        else:
            used = f"used {budget_usage_amount(b, mtd) / monthly * 100:.0f}%"
        lines.append(f"  {b.name}")
        lines.append(
            "    "
            + "  ".join(
                [
                    limit_label(b),
                    f"actual {money_display(b.actual)}",
                    f"forecast {money_display(b.forecast)}",
                    used,
                    paint(status, STATUS_COLOR.get(status), color),
                ]
            )
        )
    return lines


def render_spend(months: list[MonthSpend], color: bool) -> list[str]:
    lines = ["SPEND  UnblendedCost (target)"]
    if not months:
        lines.append("  (no complete-month CE data)")
        return lines
    med = spend_median(months)
    amount_width = max(len(money_display(m.amount)) for m in months)
    for m in months:
        flag = month_flag(m.amount, med)
        row = f"  {m.month}  {money_display(m.amount).rjust(amount_width)}"
        if flag:
            row += "  " + paint(flag, FLAG_COLOR.get(flag), color)
        lines.append(row)
    return lines


def render_report(
    *,
    hub_display: str,
    account_display: str,
    alarms: list[AlarmRow],
    budgets: list[BudgetRow],
    months: list[MonthSpend],
    mtd: float,
    months_requested: int,
    verdict: str,
    color: bool = False,
    now: datetime | None = None,
) -> str:
    now = now or datetime.now(timezone.utc)
    today = now.date()
    utc_stamp = now.strftime("%Y-%m-%d %H:%M") + "Z"
    lines: list[str] = []

    title = "Account billing review"
    lines.append(title)
    lines.append("=" * len(title))
    lines.extend(
        aligned_fields(
            [
                ("Hub", hub_display),
                ("Account", account_display),
                ("Region", BILLING_REGION),
                ("When", utc_stamp),
            ]
        )
    )
    lines.append("")

    verdict_color = VERDICT_COLOR.get(verdict, ANSI_YELLOW)
    lines.append(f"VERDICT  {paint(verdict, verdict_color, color)}")
    for detail in verdict_detail_lines(months):
        lines.append(f"  {detail}")
    lines.append("")

    snap: list[tuple[str, str]] = [("MTD", f"{money_display(mtd)}  ({mtd_span_label(today)})")]
    if months:
        last = months[-1]
        snap.append(("Last month", f"{money_display(last.amount)}  ({month_abbr(last.month)})"))
    sums = window_sums(months, months_requested)
    if sums:
        snap.append(sums)
    lines.append("SNAPSHOT")
    lines.extend(aligned_fields(snap, indent="  "))
    lines.append("")

    lines.extend(render_alarms(alarms, color))
    lines.append("")
    lines.extend(render_budgets(budgets, mtd, color))
    lines.append("")
    lines.extend(render_spend(months, color))
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as e:
        if e.code in (0, None):
            return 0
        return 1

    reject_env_credentials()

    spinner = Spinner()
    try:
        spinner.start("resolving accounts")
        try:
            hub_session = make_session(args.hub)
            target_session = make_session(args.account)
            hub_id = caller_identity(hub_session)
            target_id = caller_identity(target_session)
            hub_alias = account_alias(hub_session)
            target_alias = account_alias(target_session)
        except (ClientError, BotoCoreError) as e:
            spinner.stop()
            die(f"AWS error resolving identities: {e}", 2)

        if hub_id["account_id"] == target_id["account_id"]:
            spinner.stop()
            die(
                "Hub and account profiles resolve to the same account "
                f"({hub_id['account_id']}); pass a member --account",
                1,
            )

        try:
            cw = hub_session.client("cloudwatch", region_name=BILLING_REGION)
            budgets_client = hub_session.client("budgets", region_name=BILLING_REGION)
            ce = target_session.client("ce", region_name=BILLING_REGION)

            spinner.start("CloudWatch alarms")
            alarms = collect_target_alarms(cw, target_id["account_id"])

            spinner.start("Budgets")
            budgets = collect_target_budgets(
                budgets_client,
                hub_id["account_id"],
                target_id["account_id"],
                args.budget,
            )

            spinner.start("Cost Explorer")
            months = fetch_monthly_spend(ce, args.months)
            mtd = fetch_mtd_spend(ce)
        except (ClientError, BotoCoreError) as e:
            spinner.stop()
            die(f"AWS error during review: {e}", 2)

        verdict = classify_spend(months)
        report = render_report(
            hub_display=account_label(hub_alias, hub_id["account_id"]),
            account_display=account_label(target_alias, target_id["account_id"]),
            alarms=alarms,
            budgets=budgets,
            months=months,
            mtd=mtd,
            months_requested=args.months,
            verdict=verdict,
            color=color_enabled(args.color),
        )
        spinner.stop()
        sys.stdout.write(report)
        return 0
    finally:
        spinner.stop()


if __name__ == "__main__":
    raise SystemExit(main())
