#!/bin/bash

set -euo pipefail

# Read-only: find an IAM role across logged-in AWS SSO profiles.
# IAM is global; --region us-east-1 is only a CLI signing dummy.

AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
IAM_REGION="us-east-1"
AWS_ENV_VARS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

QUERY=""
ROLE_NAME=""
PROFILES=()
HITS=()
FOUND=0
SCANNED=0
SKIPPED=0

usage() {
    cat << EOF
Usage: $0 QUERY [OPTIONS]
       $0 --role-name NAME [OPTIONS]

Search IAM roles across AWS SSO profiles in ~/.aws/config.
SSO login required per profile. Static env credentials are refused.

  QUERY                 Substring match on RoleName and Arn (case-sensitive)
  --role-name NAME      Exact RoleName via get-role (one call per account)
  --profile, -p NAME    Limit to this profile (repeatable)
  --profiles LIST       Comma-separated profile names
  --help, -h            Show this help message

STS / AccessDenied on a profile is skipped, not fatal.

Prints an aligned table (ACCOUNT | PROFILE | ROLE | ARN).
Exit 0 if at least one match, 1 if none (or no reachable profiles).

Examples:
  $0 Admin
  $0 --role-name OrganizationAccountAccessRole
  $0 AWSReservedSSO_ --profile prod --profile staging
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

# Rows are ACCOUNT<TAB>PROFILE<TAB>ROLE<TAB>ARN. Align like aws-sso-check.sh.
print_table() {
    local h_account="ACCOUNT"
    local h_profile="PROFILE"
    local h_role="ROLE"
    local h_arn="ARN"
    local w_account=${#h_account}
    local w_profile=${#h_profile}
    local w_role=${#h_role}
    local w_arn=${#h_arn}
    local row account profile role arn

    if [[ $# -eq 0 ]]; then
        info "no matches"
        return 0
    fi

    for row in "$@"; do
        IFS=$'\t' read -r account profile role arn <<< "$row"
        w_account=$(_col_width "$w_account" "$account")
        w_profile=$(_col_width "$w_profile" "$profile")
        w_role=$(_col_width "$w_role" "$role")
        w_arn=$(_col_width "$w_arn" "$arn")
    done

    printf "%-*s | %-*s | %-*s | %s\n" \
        "$w_account" "$h_account" \
        "$w_profile" "$h_profile" \
        "$w_role" "$h_role" \
        "$h_arn"
    printf "%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_account")" \
        "$(_dashes "$w_profile")" \
        "$(_dashes "$w_role")" \
        "$(_dashes "$w_arn")"
    for row in "$@"; do
        IFS=$'\t' read -r account profile role arn <<< "$row"
        printf "%-*s | %-*s | %-*s | %s\n" \
            "$w_account" "$account" \
            "$w_profile" "$profile" \
            "$w_role" "$role" \
            "$arn"
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

self_check() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'EOF'
[profile keep-me]
sso_session = org
region = us-east-1

[profile skip-me]
region = us-east-1

[default]
sso_start_url = https://example.awsapps.com/start
sso_account_id = 111111111111
sso_role_name = Admin
EOF
    local got
    got=$(discover_sso_profiles "$tmp" | sort | tr '\n' ' ')
    rm -f "$tmp"
    [[ "$got" == "default keep-me " ]] || {
        error "self-check failed: got '$got'"
        exit 1
    }
    local table hdr r1 r2
    table=$(print_table \
        $'111111111111\tshort\tAdmin\tarn:aws:iam::111111111111:role/Admin' \
        $'222222222222\tlonger-profile\tOrganizationAccountAccessRole\tarn:aws:iam::222222222222:role/OrganizationAccountAccessRole')
    hdr=$(printf '%s\n' "$table" | sed -n '1p')
    r1=$(printf '%s\n' "$table" | sed -n '3p')
    r2=$(printf '%s\n' "$table" | sed -n '4p')
    [[ "$hdr" == ACCOUNT*PROFILE*ROLE*ARN* ]] || {
        error "self-check failed: header '$hdr'"
        exit 1
    }
    local p1 p2
    p1=${r1%%Admin*}
    p2=${r2%%OrganizationAccountAccessRole*}
    [[ ${#p1} -eq ${#p2} ]] || {
        error "self-check failed: ROLE column misaligned"
        exit 1
    }
    echo "self-check ok"
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --self-check)
                self_check
                ;;
            --role-name|--role-name=*)
                if [[ "$1" == --role-name=* ]]; then
                    ROLE_NAME="${1#*=}"
                    shift
                elif [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --role-name requires a value"
                    exit 2
                else
                    ROLE_NAME="$2"
                    shift 2
                fi
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
                if [[ -n "$QUERY" ]]; then
                    error "Unexpected argument: $1"
                    exit 2
                fi
                QUERY="$1"
                shift
                ;;
        esac
    done
}

sts_account() {
    local profile="$1"
    aws sts get-caller-identity \
        --profile "$profile" \
        --region "$IAM_REGION" \
        --query Account \
        --output text \
        --no-cli-pager 2>/dev/null
}

search_exact() {
    local profile="$1"
    local err out
    err=$(mktemp)
    if out=$(aws iam get-role \
        --profile "$profile" \
        --region "$IAM_REGION" \
        --role-name "$ROLE_NAME" \
        --query 'Role.[RoleName,Arn]' \
        --output text \
        --no-cli-pager 2>"$err"); then
        rm -f "$err"
        printf '%s\n' "$out"
        return 0
    fi
    if grep -q NoSuchEntity "$err" 2>/dev/null; then
        rm -f "$err"
        return 0
    fi
    warn "iam get-role failed for profile '$profile': $(tr '\n' ' ' < "$err")"
    rm -f "$err"
    return 0
}

search_substring() {
    local profile="$1"
    # ponytail: JMESPath contains() via aws --query; reject quotes/backticks if QUERY grows wildcards
    aws iam list-roles \
        --profile "$profile" \
        --region "$IAM_REGION" \
        --query "Roles[?contains(RoleName, \`${QUERY}\`) || contains(Arn, \`${QUERY}\`)].[RoleName,Arn]" \
        --output text \
        --no-cli-pager 2>/dev/null || {
        warn "iam list-roles failed for profile '$profile'"
        return 0
    }
}

collect_hits() {
    local account="$1"
    local profile="$2"
    local rows="$3"
    [[ -z "$rows" ]] && return 0
    local name arn rest
    while IFS=$'\t' read -r name arn rest; do
        [[ -z "${name:-}" ]] && continue
        HITS+=("${account}"$'\t'"${profile}"$'\t'"${name}"$'\t'"${arn}")
        FOUND=$((FOUND + 1))
    done <<< "$rows"
}

main() {
    parse_args "$@"
    check_dependencies
    refuse_env_credentials

    if [[ -z "$ROLE_NAME" && -z "$QUERY" ]]; then
        error "Provide QUERY or --role-name"
        usage
        exit 2
    fi
    if [[ -n "$ROLE_NAME" && -n "$QUERY" ]]; then
        error "Use QUERY or --role-name, not both"
        exit 2
    fi

    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        mapfile -t PROFILES < <(discover_sso_profiles "$AWS_CONFIG_FILE")
    fi
    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        error "No SSO profiles in $AWS_CONFIG_FILE"
        exit 1
    fi

    local profile account rows
    for profile in "${PROFILES[@]}"; do
        if ! account=$(sts_account "$profile"); then
            warn "skip '$profile' (not logged in; aws sso login --profile $profile)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        SCANNED=$((SCANNED + 1))
        if [[ -n "$ROLE_NAME" ]]; then
            rows=$(search_exact "$profile")
        else
            rows=$(search_substring "$profile")
        fi
        collect_hits "$account" "$profile" "$rows"
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
    info "scanned=$SCANNED skipped=$SKIPPED matches=$FOUND"
    [[ "$FOUND" -gt 0 ]]
}

main "$@"
