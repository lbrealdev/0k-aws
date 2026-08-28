#!/bin/bash

set -euo pipefail

# Read-only: list security-group ingress rules that allow 0.0.0.0/0 or ::/0.

PROFILE=""
REGION=""
PORTS_CSV="22,3389,445,3306,5432,1433,6379,27017,9200,2375,5985,5986"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

List security group ingress rules open to the world (0.0.0.0/0 or
::/0). Read-only. Does not modify groups.

Every matching rule is printed. SENSITIVE=yes when the port range
overlaps a watched port, uses all protocols, or covers all ports.

Options:
  --profile, -p NAME    AWS CLI profile
  --region, -r REGION   AWS region
  --ports LIST          Comma-separated watched ports
                        (default: 22,3389,445,3306,5432,1433,6379,
                        27017,9200,2375,5985,5986)
  --help, -h            Show this help message

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

ports_to_label() {
    local proto="$1"
    local from="$2"
    local to="$3"
    if [ "$proto" = "-1" ]; then
        printf '%s' "all"
        return
    fi
    if [ -z "$from" ] || [ "$from" = "null" ]; then
        from="0"
    fi
    if [ -z "$to" ] || [ "$to" = "null" ]; then
        to="65535"
    fi
    if [ "$from" = "$to" ]; then
        printf '%s' "$from"
    else
        printf '%s-%s' "$from" "$to"
    fi
}

is_sensitive() {
    local proto="$1"
    local from="$2"
    local to="$3"
    local watched="$4"
    local p
    local -a watched_ports=()

    if [ "$proto" = "-1" ]; then
        return 0
    fi
    if [ -z "$from" ] || [ "$from" = "null" ]; then
        from="0"
    fi
    if [ -z "$to" ] || [ "$to" = "null" ]; then
        to="65535"
    fi
    if [ "$from" = "0" ] && [ "$to" = "65535" ]; then
        return 0
    fi
    IFS=',' read -ra watched_ports <<< "$watched"
    for p in "${watched_ports[@]}"; do
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        [ -z "$p" ] && continue
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if [ "$p" -ge "$from" ] && [ "$p" -le "$to" ]; then
            return 0
        fi
    done
    return 1
}

print_table() {
    local h_id="GROUP_ID"
    local h_name="NAME"
    local h_vpc="VPC"
    local h_proto="PROTO"
    local h_ports="PORTS"
    local h_cidr="CIDR"
    local h_sens="SENSITIVE"
    local w_id=${#h_id}
    local w_name=${#h_name}
    local w_vpc=${#h_vpc}
    local w_proto=${#h_proto}
    local w_ports=${#h_ports}
    local w_cidr=${#h_cidr}
    local w_sens=${#h_sens}
    local row id name vpc proto ports cidr sens

    if [ $# -eq 0 ]; then
        info "no world-open ingress rules"
        return 0
    fi

    for row in "$@"; do
        IFS=$'\t' read -r id name vpc proto ports cidr sens <<< "$row"
        w_id=$(_col_width "$w_id" "$id")
        w_name=$(_col_width "$w_name" "$name")
        w_vpc=$(_col_width "$w_vpc" "$vpc")
        w_proto=$(_col_width "$w_proto" "$proto")
        w_ports=$(_col_width "$w_ports" "$ports")
        w_cidr=$(_col_width "$w_cidr" "$cidr")
        w_sens=$(_col_width "$w_sens" "$sens")
    done

    printf "%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n" \
        "$w_id" "$h_id" \
        "$w_name" "$h_name" \
        "$w_vpc" "$h_vpc" \
        "$w_proto" "$h_proto" \
        "$w_ports" "$h_ports" \
        "$w_cidr" "$h_cidr" \
        "$h_sens"
    printf "%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_id")" \
        "$(_dashes "$w_name")" \
        "$(_dashes "$w_vpc")" \
        "$(_dashes "$w_proto")" \
        "$(_dashes "$w_ports")" \
        "$(_dashes "$w_cidr")" \
        "$(_dashes "$w_sens")"
    for row in "$@"; do
        IFS=$'\t' read -r id name vpc proto ports cidr sens <<< "$row"
        printf "%-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %s\n" \
            "$w_id" "$id" \
            "$w_name" "$name" \
            "$w_vpc" "$vpc" \
            "$w_proto" "$proto" \
            "$w_ports" "$ports" \
            "$w_cidr" "$cidr" \
            "$sens"
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
            --ports)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --ports requires a value"
                    exit 1
                fi
                PORTS_CSV="$2"
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

    check_dependencies

    local raw
    if ! raw=$(aws_json ec2 describe-security-groups); then
        error "ec2 describe-security-groups failed"
        exit 2
    fi

    local line id name vpc proto from to cidr ports sens
    local rows=()
    local sensitive_count=0

    while IFS=$'\t' read -r id name vpc proto from to cidr; do
        [ -z "$id" ] && continue
        ports=$(ports_to_label "$proto" "$from" "$to")
        if is_sensitive "$proto" "$from" "$to" "$PORTS_CSV"; then
            sens="yes"
            sensitive_count=$((sensitive_count + 1))
        else
            sens="no"
        fi
        rows+=("${id}"$'\t'"${name}"$'\t'"${vpc}"$'\t'"${proto}"$'\t'"${ports}"$'\t'"${cidr}"$'\t'"${sens}")
    done < <(printf '%s' "$raw" | jq -r '
        .SecurityGroups[]? as $sg
        | ($sg.IpPermissions // [])[]? as $p
        | (
            (($p.IpRanges // [])[]? | {cidr: .CidrIp}),
            (($p.Ipv6Ranges // [])[]? | {cidr: .CidrIpv6})
          ) as $r
        | select($r.cidr == "0.0.0.0/0" or $r.cidr == "::/0")
        | [
            $sg.GroupId,
            ($sg.GroupName // "-"),
            ($sg.VpcId // "-"),
            ($p.IpProtocol // "-"),
            ($p.FromPort | if . == null then "" else tostring end),
            ($p.ToPort | if . == null then "" else tostring end),
            $r.cidr
          ]
        | @tsv
    ')

    print_table "${rows[@]+"${rows[@]}"}"

    info "world-open rules: ${#rows[@]}  sensitive: $sensitive_count"
}

main "$@"
