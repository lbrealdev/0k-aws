#!/bin/bash

set -euo pipefail

# Read-only: list RDS instance and cluster snapshots with age in days.

PROFILE=""
REGION=""
MIN_AGE=30
SNAPSHOT_TYPE="all"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

List RDS DB and cluster snapshots with age in days (UTC). Read-only.
Does not delete snapshots. Complements the RDS deletion checklist:
manual snapshots persist after instance delete and incur storage cost.

Rows with AGE_DAYS >= --min-age are flagged OLD=yes.

Options:
  --profile, -p NAME         AWS CLI profile
  --region, -r REGION        AWS region
  --min-age DAYS             Flag snapshots this old or older
                             (default: 30)
  --snapshot-type TYPE       automated, manual, or all
                             (default: all)
  --help, -h                 Show this help message

EOF
}

error() { echo "[ERROR] $*" >&2; }
info()  { echo "[INFO]  $*" >&2; }

_col_width() {
    local current="$1"
    local value="$2"
    local len=${#value}
    if [ "$len" -gt "$current" ]; then
        echo "$len"
    else
        echo "$current"
    fi
}

_dashes() {
    printf '%*s' "$1" '' | tr ' ' '-'
}

check_dependencies() {
    if ! command -v aws >/dev/null 2>&1; then
        error "aws CLI is not installed or not in PATH"
        exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is not installed or not in PATH"
        exit 2
    fi
}

aws_json() {
    local -a cmd=(aws)
    [ -n "$PROFILE" ] && cmd+=(--profile "$PROFILE")
    [ -n "$REGION" ] && cmd+=(--region "$REGION")
    cmd+=("$@" --output json --no-cli-pager)
    "${cmd[@]}"
}

# ISO-8601 from AWS -> age in whole days (UTC). Empty input -> "?".
age_days() {
    local iso="$1"
    local created_epoch now
    if [ -z "$iso" ] || [ "$iso" = "null" ]; then
        printf '%s' "?"
        return
    fi
    if ! created_epoch=$(date -u -d "$iso" +%s 2>/dev/null); then
        printf '%s' "?"
        return
    fi
    now=$(date -u +%s)
    printf '%s' "$(( (now - created_epoch) / 86400 ))"
}

print_table() {
    local h_kind="KIND"
    local h_id="SNAPSHOT"
    local h_engine="ENGINE"
    local h_type="TYPE"
    local h_age="AGE_DAYS"
    local h_enc="ENCRYPTED"
    local h_old="OLD"
    local w_kind=${#h_kind}
    local w_id=${#h_id}
    local w_engine=${#h_engine}
    local w_type=${#h_type}
    local w_age=${#h_age}
    local w_enc=${#h_enc}
    local w_old=${#h_old}
    local row kind id engine stype age enc old

    if [ $# -eq 0 ]; then
        info "no snapshots"
        return 0
    fi

    for row in "$@"; do
        IFS=$'\t' read -r kind id engine stype age enc old <<< "$row"
        w_kind=$(_col_width "$w_kind" "$kind")
        w_id=$(_col_width "$w_id" "$id")
        w_engine=$(_col_width "$w_engine" "$engine")
        w_type=$(_col_width "$w_type" "$stype")
        w_age=$(_col_width "$w_age" "$age")
        w_enc=$(_col_width "$w_enc" "$enc")
        w_old=$(_col_width "$w_old" "$old")
    done

    printf "%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n" \
        "$w_kind" "$h_kind" \
        "$w_id" "$h_id" \
        "$w_engine" "$h_engine" \
        "$w_type" "$h_type" \
        "$w_age" "$h_age" \
        "$w_enc" "$h_enc" \
        "$h_old"
    printf "%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_kind")" \
        "$(_dashes "$w_id")" \
        "$(_dashes "$w_engine")" \
        "$(_dashes "$w_type")" \
        "$(_dashes "$w_age")" \
        "$(_dashes "$w_enc")" \
        "$(_dashes "$w_old")"
    for row in "$@"; do
        IFS=$'\t' read -r kind id engine stype age enc old <<< "$row"
        printf "%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n" \
            "$w_kind" "$kind" \
            "$w_id" "$id" \
            "$w_engine" "$engine" \
            "$w_type" "$stype" \
            "$w_age" "$age" \
            "$w_enc" "$enc" \
            "$old"
    done
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile|-p)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --profile requires a value"
                    exit 1
                fi
                PROFILE="$2"
                shift 2
                ;;
            --region|-r)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --region requires a value"
                    exit 1
                fi
                REGION="$2"
                shift 2
                ;;
            --min-age)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --min-age requires a value"
                    exit 1
                fi
                MIN_AGE="$2"
                shift 2
                ;;
            --snapshot-type)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --snapshot-type requires a value"
                    exit 1
                fi
                SNAPSHOT_TYPE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done

    case "$SNAPSHOT_TYPE" in
        automated|manual|all) ;;
        *)
            error "--snapshot-type must be automated, manual, or all"
            exit 1
            ;;
    esac
    if ! [[ "$MIN_AGE" =~ ^[0-9]+$ ]]; then
        error "--min-age must be a non-negative integer"
        exit 1
    fi

    check_dependencies

    local db_json cluster_json
    if ! db_json=$(aws_json rds describe-db-snapshots); then
        error "rds describe-db-snapshots failed"
        exit 2
    fi
    if ! cluster_json=$(aws_json rds describe-db-cluster-snapshots); then
        error "rds describe-db-cluster-snapshots failed"
        exit 2
    fi

    local rows=()
    local old_count=0
    local line kind id engine stype created enc age old

    while IFS=$'\t' read -r kind id engine stype created enc; do
        [ -z "$kind" ] && continue
        age=$(age_days "$created")
        old="no"
        if [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -ge "$MIN_AGE" ]; then
            old="yes"
            old_count=$((old_count + 1))
        fi
        rows+=("${kind}"$'\t'"${id}"$'\t'"${engine}"$'\t'"${stype}"$'\t'"${age}"$'\t'"${enc}"$'\t'"${old}")
    done < <(
        {
            printf '%s' "$db_json" | jq -r --arg type_filter "$SNAPSHOT_TYPE" '
                .DBSnapshots[]? as $s
                | ($s.SnapshotType // "") as $t
                | select(($type_filter == "all") or ($type_filter == $t))
                | [
                    "instance",
                    ($s.DBSnapshotIdentifier // "-"),
                    ($s.Engine // "-"),
                    ($t | if . == "" then "-" else . end),
                    ($s.SnapshotCreateTime // ""),
                    (if $s.Encrypted == true then "yes" else "no" end)
                  ]
                | @tsv
            '
            printf '%s' "$cluster_json" | jq -r --arg type_filter "$SNAPSHOT_TYPE" '
                .DBClusterSnapshots[]? as $s
                | ($s.SnapshotType // "") as $t
                | select(($type_filter == "all") or ($type_filter == $t))
                | [
                    "cluster",
                    ($s.DBClusterSnapshotIdentifier // "-"),
                    ($s.Engine // "-"),
                    ($t | if . == "" then "-" else . end),
                    ($s.SnapshotCreateTime // ""),
                    (if $s.StorageEncrypted == true then "yes" else "no" end)
                  ]
                | @tsv
            '
        }
    )

    print_table "${rows[@]+"${rows[@]}"}"
    info "snapshots: ${#rows[@]}  old (>= ${MIN_AGE}d): $old_count"
}

main "$@"
