#!/bin/bash

set -euo pipefail

AWS_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
AWS_ENV_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN")

TMPFILE=""
trap 'rm -f "$TMPFILE"' EXIT

CHECK_CONFIG=false

if [ -t 1 ]; then
  GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; GRAY="\e[90m"; RESET="\e[0m"
else
  GREEN=""; YELLOW=""; BLUE=""; RED=""; GRAY=""; RESET=""
fi

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Validate local AWS SSO profiles can authenticate (STS + account alias),
or inspect ~/.aws/config for SSO profiles without logging in.

Options:
  --check-config     Inspect ~/.aws/config for SSO profiles; no login required
  --help, -h         Show this help message

EOF
}

now() { date +"%Y-%m-%d %H:%M:%S"; }

log_info()  { echo -e "[$(now)] ${BLUE}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "[$(now)] ${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "[$(now)] ${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "[$(now)] ${RED}[ERROR]${RESET} $*"; }

check_aws_cli() {
    log_info "Checking prerequisites..."
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed or not in PATH"
        exit 1
    fi
    local ver
    ver=$(aws --version 2>&1)
    if [[ "$ver" =~ aws-cli/([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        log_ok "AWS CLI: aws-cli/${BASH_REMATCH[1]}"
    else
        log_ok "AWS CLI: installed"
    fi
}

_mask() {
  local v="$1"
  [ -z "$v" ] && { echo "<empty>"; return; }
  local visible=4
  if [ "${#v}" -le "$visible" ]; then
    echo "${v}<sensitive>"
  else
    echo "${v:0:$visible}<sensitive>"
  fi
}

check_aws_env_vars() {
    local found=()

    log_info "Checking for conflicting environment variables..."

    for var in "${AWS_ENV_VARS[@]}"; do
        if [ -n "${!var:-}" ]; then
            found+=("$var=$(_mask "${!var}")")
        fi
    done

    if [ ${#found[@]} -gt 0 ]; then
        log_error "AWS environment variables are set. These may interfere with SSO authentication."
        for line in "${found[@]}"; do
            echo -e "   - $line"
        done
        log_info "Unset them with: unset ${AWS_ENV_VARS[*]}"
        exit 1
    fi

    log_ok "No conflicting environment variables found"
}

check_sso_session() {
    log_info "Verifying AWS SSO session..."

    local identity
    if ! identity=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null); then
        log_error "No active SSO session. Please run 'aws sso login' and try again."
        exit 1
    fi

    log_ok "SSO session active: $identity"
}

# Emit one line per SSO profile:
#   name|method|sso_session|sso_account_id|sso_role_name
# method is "session" (sso_session=) or "legacy" (inline sso_* keys).
discover_sso_profiles() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return
    fi

    local profile_name=""
    local sso_session=""
    local sso_start_url=""
    local sso_account_id=""
    local sso_role_name=""

    emit_if_sso() {
        [ -z "$profile_name" ] && return 0
        local method=""
        if [ -n "$sso_session" ]; then
            method="session"
        elif [ -n "$sso_start_url" ] || { [ -n "$sso_account_id" ] && [ -n "$sso_role_name" ]; }; then
            method="legacy"
        else
            return 0
        fi
        printf '%s|%s|%s|%s|%s\n' \
            "$profile_name" "$method" "$sso_session" "$sso_account_id" "$sso_role_name"
    }

    reset_section() {
        profile_name=""
        sso_session=""
        sso_start_url=""
        sso_account_id=""
        sso_role_name=""
    }

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        # skip comments / blank
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue

        if [[ "$line" =~ ^\[profile[[:space:]]+([^\]]+)\] ]]; then
            emit_if_sso
            reset_section
            profile_name="${BASH_REMATCH[1]}"
            # trim whitespace
            profile_name="${profile_name#"${profile_name%%[![:space:]]*}"}"
            profile_name="${profile_name%"${profile_name##*[![:space:]]}"}"
            continue
        fi

        if [[ "$line" =~ ^\[default\] ]]; then
            emit_if_sso
            reset_section
            profile_name="default"
            continue
        fi

        # skip other sections (e.g. sso-session)
        if [[ "$line" =~ ^\[ ]]; then
            emit_if_sso
            reset_section
            continue
        fi

        [ -z "$profile_name" ] && continue

        if [[ "$line" =~ ^[[:space:]]*sso_session[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            sso_session="${BASH_REMATCH[1]}"
            sso_session="${sso_session%"${sso_session##*[![:space:]]}"}"
        elif [[ "$line" =~ ^[[:space:]]*sso_start_url[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            sso_start_url="${BASH_REMATCH[1]}"
            sso_start_url="${sso_start_url%"${sso_start_url##*[![:space:]]}"}"
        elif [[ "$line" =~ ^[[:space:]]*sso_account_id[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            sso_account_id="${BASH_REMATCH[1]}"
            sso_account_id="${sso_account_id%"${sso_account_id##*[![:space:]]}"}"
        elif [[ "$line" =~ ^[[:space:]]*sso_role_name[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            sso_role_name="${BASH_REMATCH[1]}"
            sso_role_name="${sso_role_name%"${sso_role_name##*[![:space:]]}"}"
        fi
    done < "$config_file"

    emit_if_sso
}

warn_static_credentials() {
    local creds_file="$1"
    [ ! -f "$creds_file" ] && return 0

    local current=""

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            current="${BASH_REMATCH[1]}"
        elif [ -n "$current" ] && [[ "$line" =~ ^[[:space:]]*aws_access_key_id[[:space:]]*= ]]; then
            log_warn "Static credentials in [$current] ($creds_file); SSO discovery uses $AWS_CONFIG_FILE only"
            current=""
        fi
    done < "$creds_file"
}

validate_profile() {
    local profile="$1"

    export AWS_PROFILE="$profile"

    local account_id
    if ! account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null); then
        return 1
    fi

    local alias
    alias=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null) || alias="<no-alias>"
    [ -z "$alias" ] || [ "$alias" = "None" ] && alias="<no-alias>"

    echo "$account_id|$alias|$profile"
    return 0
}

run_check_config() {
    log_info "Inspecting SSO profiles in $AWS_CONFIG_FILE (no login)..."

    if [ ! -f "$AWS_CONFIG_FILE" ]; then
        log_error "Config file not found: $AWS_CONFIG_FILE"
        exit 1
    fi

    local rows
    rows=$(discover_sso_profiles "$AWS_CONFIG_FILE")

    if [ -z "$rows" ]; then
        log_error "No SSO profiles found in $AWS_CONFIG_FILE"
        exit 1
    fi

    local profile_count
    profile_count=$(printf '%s\n' "$rows" | grep -c . || true)

    log_ok "Found $profile_count SSO profile(s)"
    echo ""
    printf "%-20s | %-8s | %-16s | %-14s | %s\n" "PROFILE" "METHOD" "ACCOUNT" "SESSION/ROLE" "DETAIL"
    printf "%-20s-+-%-8s-+-%-16s-+-%-14s-+-%s\n" "--------------------" "--------" "----------------" "--------------" "------"

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local name method session account role detail
        IFS='|' read -r name method session account role <<< "$row"
        if [ "$method" = "session" ]; then
            detail="sso_session=$session"
            printf "%-20s | %-8s | %-16s | %-14s | %s\n" \
                "$name" "$method" "${account:-<unset>}" "${session:-<unset>}" "$detail"
        else
            detail="sso_role_name=${role:-<unset>}"
            printf "%-20s | %-8s | %-16s | %-14s | %s\n" \
                "$name" "$method" "${account:-<unset>}" "${role:-<unset>}" "$detail"
        fi
    done <<< "$rows"

    echo ""
    echo "---"
    echo "Config-only check: $profile_count SSO profile(s) in $AWS_CONFIG_FILE"
}

run_validate() {
    check_aws_cli
    check_aws_env_vars
    check_sso_session

    log_info "Discovering SSO profiles in $AWS_CONFIG_FILE..."

    if [ ! -f "$AWS_CONFIG_FILE" ]; then
        log_error "Config file not found: $AWS_CONFIG_FILE"
        exit 1
    fi

    warn_static_credentials "$AWS_CREDENTIALS_FILE"

    local rows
    rows=$(discover_sso_profiles "$AWS_CONFIG_FILE")

    if [ -z "$rows" ]; then
        log_error "No SSO profiles found in $AWS_CONFIG_FILE"
        exit 1
    fi

    local profile_count
    profile_count=$(printf '%s\n' "$rows" | grep -c . || true)

    log_ok "Found $profile_count SSO profile(s)"

    echo ""
    log_info "Validating profiles..."
    echo ""

    local success_count=0
    local failure_count=0

    TMPFILE=$(mktemp)
    printf '%s\n' "$rows" > "$TMPFILE"

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local profile method session account_cfg role
        IFS='|' read -r profile method session account_cfg role <<< "$row"

        local result
        if result=$(validate_profile "$profile"); then
            success_count=$((success_count + 1))
            local account_id alias
            account_id=$(echo "$result" | cut -d'|' -f1)
            alias=$(echo "$result" | cut -d'|' -f2)
            printf "${GREEN}[OK]${RESET} %-12s | %-20s | %s - authenticated successfully\n" "$account_id" "$alias" "$profile"
        else
            failure_count=$((failure_count + 1))
            local account_id="${account_cfg:-<unknown>}"
            [ -z "$account_id" ] && account_id="<unknown>"
            printf "${RED}[FAIL]${RESET} %-12s | %-20s | %s - failed to authenticate\n" "$account_id" "<no-alias>" "$profile"
        fi
    done < "$TMPFILE"

    rm -f "$TMPFILE"
    TMPFILE=""

    echo ""
    echo "---"
    echo "Validated: $profile_count profile(s)"
    echo -e "Succeeded: ${GREEN}$success_count${RESET}"
    echo -e "Failed:    ${RED}$failure_count${RESET}"

    if [ "$failure_count" -gt 0 ]; then
        exit 1
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-config)
                CHECK_CONFIG=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    echo "#========================================#"
    echo "#     AWS SSO PROFILES CHECK SCRIPT      #"
    echo "#========================================#"
    echo ""

    if [ "$CHECK_CONFIG" = true ]; then
        run_check_config
    else
        run_validate
    fi
}

main "$@"
