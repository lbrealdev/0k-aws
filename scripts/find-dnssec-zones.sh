#!/bin/bash

set -euo pipefail

# Read-only: find Route 53 public hosted zones with DNSSEC signing across
# logged-in AWS SSO profiles. Route 53 is global; --region us-east-1 is only
# a CLI signing dummy.

AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
R53_REGION="us-east-1"
AWS_ENV_VARS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

SHOW_ALL=0
PROFILES=()
HITS=()
FOUND=0
ZONES=0
SCANNED=0
SKIPPED=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS]
       $0 --check

Find Route 53 public hosted zones with DNSSEC signing across AWS SSO
profiles. By default only zones whose status is not NOT_SIGNING are shown.

Options:
  --all, -a          Show every public zone with its DNSSEC status
  --profile, -p NAME Limit to this profile
  --profiles LIST    Comma-separated profiles
  --check            Validate SSO profiles in ~/.aws/config
  --help, -h         Show this help
EOF
}

error() { echo "[ERROR] $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
info()  { echo "[INFO]  $*" >&2; }

_col_width() {
    local current="$1"
    local value="$2"
    local len=${#value}
    if [[ "$len" -gt "$current" ]]; then
        echo "$len"
    else
        echo "$current"
    fi
}

_dashes() {
    printf '%*s' "$1" '' | tr ' ' '-'
}

# Rows are ACCOUNT<TAB>PROFILE<TAB>ZONE<TAB>ZONE_ID<TAB>DNSSEC.
print_table() {
    local h_account="ACCOUNT"
    local h_profile="PROFILE"
    local h_zone="ZONE"
    local h_id="ZONE ID"
    local h_status="DNSSEC"
    local w_account=${#h_account}
    local w_profile=${#h_profile}
    local w_zone=${#h_zone}
    local w_id=${#h_id}
    local row account profile zone id status

    if [[ $# -eq 0 ]]; then
        info "no matches"
        return 0
    fi

    for row in "$@"; do
        IFS=$'\t' read -r account profile zone id status <<< "$row"
        w_account=$(_col_width "$w_account" "$account")
        w_profile=$(_col_width "$w_profile" "$profile")
        w_zone=$(_col_width "$w_zone" "$zone")
        w_id=$(_col_width "$w_id" "$id")
    done

    printf "%-*s | %-*s | %-*s | %-*s | %s\n" \
        "$w_account" "$h_account" \
        "$w_profile" "$h_profile" \
        "$w_zone" "$h_zone" \
        "$w_id" "$h_id" \
        "$h_status"
    printf "%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_account")" \
        "$(_dashes "$w_profile")" \
        "$(_dashes "$w_zone")" \
        "$(_dashes "$w_id")" \
        "$(_dashes "${#h_status}")"
    for row in "$@"; do
        IFS=$'\t' read -r account profile zone id status <<< "$row"
        printf "%-*s | %-*s | %-*s | %-*s | %s\n" \
            "$w_account" "$account" \
            "$w_profile" "$profile" \
            "$w_zone" "$zone" \
            "$w_id" "$id" \
            "$status"
    done
}

check_dependencies() {
    if ! command -v aws >/dev/null 2>&1; then
        error "aws CLI is not installed or not in PATH"
        exit 2
    fi
}

refuse_env_credentials() {
    local found=()
    local var
    for var in "${AWS_ENV_VARS[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            found+=("$var")
        fi
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        error "SSO profiles only; unset: ${found[*]}"
        exit 2
    fi
}

# Print one SSO profile name per line.
discover_sso_profiles() {
    local config="$1"
    [[ -f "$config" ]] || return 0
    awk '
        /^\[profile / {
            emit()
            name = $0
            sub(/^\[profile[ \t]+/, "", name)
            sub(/\][ \t]*$/, "", name)
            sso = 0
            next
        }
        /^\[default\]/ {
            emit()
            name = "default"
            sso = 0
            next
        }
        /^\[/ {
            emit()
            name = ""
            sso = 0
            next
        }
        name != "" && $0 ~ /^[ \t]*(sso_session|sso_start_url|sso_account_id)[ \t]*=/ {
            sso = 1
        }
        END { emit() }
        function emit() {
            if (name != "" && sso) print name
        }
    ' "$config"
}

# Count SSO profiles in the real AWS config (no AWS API calls).
check() {
    local profiles=()
    local n=0
    mapfile -t profiles < <(discover_sso_profiles "$AWS_CONFIG_FILE")
    n=${#profiles[@]}
    echo "Found $n SSO profiles in $AWS_CONFIG_FILE"
    if [[ "$n" -eq 0 ]]; then
        exit 1
    fi
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --check)
                check
                ;;
            --all|-a)
                SHOW_ALL=1
                shift
                ;;
            --profile|--profile=*|-p|-p=*)
                if [[ "$1" == --profile=* || "$1" == -p=* ]]; then
                    PROFILES+=("${1#*=}")
                    shift
                elif [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --profile requires a value"
                    exit 2
                else
                    PROFILES+=("$2")
                    shift 2
                fi
                ;;
            --profiles)
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --profiles requires a value"
                    exit 2
                fi
                local raw profile
                IFS=',' read -ra raw <<< "$2"
                for profile in "${raw[@]}"; do
                    profile="${profile#"${profile%%[![:space:]]*}"}"
                    profile="${profile%"${profile##*[![:space:]]}"}"
                    [[ -n "$profile" ]] && PROFILES+=("$profile")
                done
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 2
                ;;
            *)
                error "Unexpected argument: $1"
                exit 2
                ;;
        esac
    done
}

# aws.exe in Git Bash ends lines with CRLF; strip \r from text output.
sts_account() {
    local profile="$1"
    aws sts get-caller-identity \
        --profile "$profile" \
        --region "$R53_REGION" \
        --query Account \
        --output text \
        --no-cli-pager 2>/dev/null | tr -d '\r'
}

# Print ZONE_ID<TAB>NAME for each public hosted zone (CLI paginates).
list_public_zones() {
    local profile="$1"
    # shellcheck disable=SC2016  # JMESPath backtick literal
    aws route53 list-hosted-zones \
        --profile "$profile" \
        --region "$R53_REGION" \
        --query 'HostedZones[?Config.PrivateZone==`false`].[Id,Name]' \
        --output text \
        --no-cli-pager | tr -d '\r'
}

dnssec_status() {
    local profile="$1"
    local zone_id="$2"
    aws route53 get-dnssec \
        --profile "$profile" \
        --region "$R53_REGION" \
        --hosted-zone-id "$zone_id" \
        --query 'Status.ServeSignature' \
        --output text \
        --no-cli-pager 2>/dev/null | tr -d '\r'
}

scan_profile() {
    local account="$1"
    local profile="$2"
    local rows id name status
    if ! rows=$(list_public_zones "$profile" 2>/dev/null); then
        warn "route53 list-hosted-zones failed for profile '$profile'"
        return 0
    fi
    [[ -z "$rows" ]] && return 0
    while IFS=$'\t' read -r id name; do
        [[ -z "${id:-}" ]] && continue
        id="${id##*/}"
        name="${name%.}"
        ZONES=$((ZONES + 1))
        if ! status=$(dnssec_status "$profile" "$id"); then
            warn "route53 get-dnssec failed for zone '$id' in '$profile'"
            status="UNKNOWN"
        fi
        if [[ "$status" != "NOT_SIGNING" ]]; then
            FOUND=$((FOUND + 1))
        elif [[ "$SHOW_ALL" -eq 0 ]]; then
            continue
        fi
        HITS+=("${account}"$'\t'"${profile}"$'\t'"${name}"$'\t'"${id}"$'\t'"${status}")
    done <<< "$rows"
}

main() {
    parse_args "$@"

    check_dependencies
    refuse_env_credentials

    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        mapfile -t PROFILES < <(discover_sso_profiles "$AWS_CONFIG_FILE")
    fi
    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        error "No SSO profiles in $AWS_CONFIG_FILE"
        exit 1
    fi

    local profile account
    for profile in "${PROFILES[@]}"; do
        if ! account=$(sts_account "$profile"); then
            warn "skip '$profile' (not logged in; aws sso login --profile $profile)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        SCANNED=$((SCANNED + 1))
        scan_profile "$account" "$profile"
    done

    if [[ "$SCANNED" -eq 0 ]]; then
        error "No reachable SSO profiles"
        exit 1
    fi

    echo ""
    if [[ ${#HITS[@]} -gt 0 ]]; then
        print_table "${HITS[@]}"
    else
        info "no matches"
    fi
    echo ""
    info "scanned=$SCANNED skipped=$SKIPPED zones=$ZONES dnssec=$FOUND"
    [[ "$FOUND" -gt 0 ]]
}

main "$@"
