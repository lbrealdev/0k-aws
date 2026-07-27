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

    local h_profile="PROFILE"
    local h_method="METHOD"
    local h_account="ACCOUNT"
    local h_session="SESSION/ROLE"
    local h_detail="DETAIL"

    local w_profile=${#h_profile}
    local w_method=${#h_method}
    local w_account=${#h_account}
    local w_session=${#h_session}
    local w_detail=${#h_detail}

    local display_rows=""
    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local name method session account role detail col4
        IFS='|' read -r name method session account role <<< "$row"
        account="${account:-<unset>}"
        if [ "$method" = "session" ]; then
            col4="${session:-<unset>}"
            detail="sso_session=$session"
        else
            col4="${role:-<unset>}"
            detail="sso_role_name=${role:-<unset>}"
        fi
        w_profile=$(_col_width "$w_profile" "$name")
        w_method=$(_col_width "$w_method" "$method")
        w_account=$(_col_width "$w_account" "$account")
        w_session=$(_col_width "$w_session" "$col4")
        w_detail=$(_col_width "$w_detail" "$detail")
        display_rows+="${name}|${method}|${account}|${col4}|${detail}"$'\n'
    done <<< "$rows"

    log_ok "Found $profile_count SSO profile(s)"
    echo ""
    printf "%-*s | %-*s | %-*s | %-*s | %-*s\n" \
        "$w_profile" "$h_profile" \
        "$w_method" "$h_method" \
        "$w_account" "$h_account" \
        "$w_session" "$h_session" \
        "$w_detail" "$h_detail"
    printf "%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_profile")" \
        "$(_dashes "$w_method")" \
        "$(_dashes "$w_account")" \
        "$(_dashes "$w_session")" \
        "$(_dashes "$w_detail")"

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local name method account col4 detail
        IFS='|' read -r name method account col4 detail <<< "$row"
        printf "%-*s | %-*s | %-*s | %-*s | %-*s\n" \
            "$w_profile" "$name" \
            "$w_method" "$method" \
            "$w_account" "$account" \
            "$w_session" "$col4" \
            "$w_detail" "$detail"
    done <<< "$display_rows"

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
    local w_account=0
    local w_alias=0
    local w_profile=0
    local display_rows=""

    TMPFILE=$(mktemp)
    printf '%s\n' "$rows" > "$TMPFILE"

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local profile method session account_cfg role
        IFS='|' read -r profile method session account_cfg role <<< "$row"

        local status account_id alias message
        local result
        if result=$(validate_profile "$profile"); then
            success_count=$((success_count + 1))
            status="OK"
            account_id=$(echo "$result" | cut -d'|' -f1)
            alias=$(echo "$result" | cut -d'|' -f2)
            message="authenticated successfully"
        else
            failure_count=$((failure_count + 1))
            status="FAIL"
            account_id="${account_cfg:-<unknown>}"
            [ -z "$account_id" ] && account_id="<unknown>"
            alias="<no-alias>"
            message="failed to authenticate"
        fi

        w_account=$(_col_width "$w_account" "$account_id")
        w_alias=$(_col_width "$w_alias" "$alias")
        w_profile=$(_col_width "$w_profile" "$profile")
        display_rows+="${status}|${account_id}|${alias}|${profile}|${message}"$'\n'
    done < "$TMPFILE"

    rm -f "$TMPFILE"
    TMPFILE=""

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local status account_id alias profile message
        IFS='|' read -r status account_id alias profile message <<< "$row"
        if [ "$status" = "OK" ]; then
            printf "${GREEN}%-6s${RESET} %-*s | %-*s | %-*s - %s\n" \
                "[OK]" "$w_account" "$account_id" "$w_alias" "$alias" "$w_profile" "$profile" "$message"
        else
            printf "${RED}%-6s${RESET} %-*s | %-*s | %-*s - %s\n" \
                "[FAIL]" "$w_account" "$account_id" "$w_alias" "$alias" "$w_profile" "$profile" "$message"
        fi
    done <<< "$display_rows"

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
