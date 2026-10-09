#!/bin/bash
# Read-only: list Route 53 public hosted zones with DNSSEC signing in every
# logged-in AWS SSO profile. Output: ACCOUNT PROFILE ZONE ZONE_ID STATUS.
set -euo pipefail

export AWS_PAGER=""   # no pager (Windows aws.exe opens one otherwise)
REGION="us-east-1"    # Route 53 is global; region is only for signing
SHOW_ALL=0

usage() {
    cat << EOF2
Usage: $0 [--all] [PROFILE...]

Print one line per public hosted zone with DNSSEC signing:
  ACCOUNT PROFILE ZONE ZONE_ID STATUS
Profiles default to 'aws configure list-profiles'.
Not-logged-in profiles are skipped (message on stderr).

  --all, -a   Also print zones with NOT_SIGNING
  --help, -h  Show this help
EOF2
}

# aws.exe in Git Bash ends lines with CRLF; strip \r from every call.
awsq() { aws "$@" --region "$REGION" --output text < /dev/null | tr -d '\r'; }

while [[ $# -gt 0 && "$1" == -* ]]; do
    case "$1" in
        --all|-a) SHOW_ALL=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v aws > /dev/null || { echo "aws CLI not found" >&2; exit 2; }

if [[ $# -gt 0 ]]; then
    profiles=("$@")
else
    mapfile -t profiles < <(aws configure list-profiles | tr -d '\r')
fi

for p in "${profiles[@]}"; do
    printf '%s...' "$p" >&2
    if ! account=$(awsq sts get-caller-identity --profile "$p" \
            --query Account 2> /dev/null) || [[ -z "$account" ]]; then
        echo >&2
        echo "skip $p (aws sso login --profile $p)" >&2
        continue
    fi
    # shellcheck disable=SC2016  # JMESPath backtick literal
    if ! zones=$(awsq route53 list-hosted-zones --profile "$p" \
        --query 'HostedZones[?Config.PrivateZone==`false`].[Id,Name]'); then
        printf ' failed\n' >&2
        continue
    fi
    n=0
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] || continue
        id=${id##*/}
        status=$(awsq route53 get-dnssec --profile "$p" --hosted-zone-id "$id" \
            --query Status.ServeSignature 2> /dev/null) || status=UNKNOWN
        n=$((n + 1))
        [[ "$status" == NOT_SIGNING && "$SHOW_ALL" -eq 0 ]] && continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$account" "$p" "${name%.}" "$id" "$status"
    done <<< "$zones"
    printf ' %d zones\n' "$n" >&2
done
