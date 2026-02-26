#!/bin/bash

set -euo pipefail

AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"
AWS_CONFIG_FILE="$HOME/.aws/config"
AWS_ENV_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN")

echo "#========================================#"
echo "#     AWS SSO PROFILES CHECK SCRIPT     #"
echo "#========================================#"
echo ""

if [ -t 1 ]; then
  GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; GRAY="\e[90m"; RESET="\e[0m"
else
  GREEN=""; YELLOW=""; BLUE=""; RED=""; GRAY=""; RESET=""
fi

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
    log_ok "AWS CLI: $(aws --version 2>&1 | grep -oP "aws-cli/\d+\.\d+\.\d+" || echo "installed")"
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

    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "No active SSO session. Please run 'aws sso login' and try again."
        exit 1
    fi

    local identity
    identity=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null)
    log_ok "SSO session active: $identity"
}

get_profiles_from_config() {
    local config_file="$1"
    local profiles=()

    if [ ! -f "$config_file" ]; then
        return
    fi

    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        local profile_name
        profile_name=$(echo "$line" | grep -oP '^\[profile\s+\K[^\]]+' || true)
        if [ -n "$profile_name" ] && [ "$profile_name" != "default" ]; then
            profiles+=("$profile_name")
        fi
    done < "$config_file"

    printf '%s\n' "${profiles[@]}"
}

get_profiles_from_credentials() {
    local creds_file="$1"
    local profiles=()

    if [ ! -f "$creds_file" ]; then
        return
    fi

    local current_profile=""
    local has_sso_config=false
    local has_static_creds=false

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r')
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            if [ -n "$current_profile" ]; then
                if [ "$has_static_creds" = true ]; then
                    log_error "Static credentials detected in profile [$current_profile]"
                    log_error "This script only supports SSO-based profiles."
                    log_error "Please remove static credential profiles from $creds_file"
                    exit 1
                fi
                if [ "$has_sso_config" = true ] && [ "$current_profile" != "default" ]; then
                    profiles+=("$current_profile")
                fi
            fi

            current_profile="${BASH_REMATCH[1]}"
            has_sso_config=false
            has_static_creds=false
        elif [ -n "$current_profile" ]; then
            if [[ "$line" =~ ^sso_(start_url|region|account_id|role_name) ]]; then
                has_sso_config=true
            fi
            if [[ "$line" =~ ^aws_(access_key_id|secret_access_key) ]]; then
                has_static_creds=true
            fi
        fi
    done < "$creds_file"

    if [ -n "$current_profile" ]; then
        if [ "$has_static_creds" = true ]; then
            log_error "Static credentials detected in profile [$current_profile]"
            log_error "This script only supports SSO-based profiles."
            log_error "Please remove static credential profiles from $creds_file"
            exit 1
        fi
        if [ "$has_sso_config" = true ] && [ "$current_profile" != "default" ]; then
            profiles+=("$current_profile")
        fi
    fi

    printf '%s\n' "${profiles[@]}"
}

merge_profiles() {
    local profiles="$1"
    echo "$profiles" | sort -u | grep -v '^$'
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
    [ -z "$alias" ] && alias="<no-alias>"

    echo "$account_id|$alias|$profile"
    return 0
}

main() {
    check_aws_cli
    check_aws_env_vars
    check_sso_session

    log_info "Discovering AWS profiles..."

    local config_profiles=""
    local creds_profiles=""

    if [ -f "$AWS_CONFIG_FILE" ]; then
        config_profiles=$(get_profiles_from_config "$AWS_CONFIG_FILE")
    else
        log_warn "Config file not found: $AWS_CONFIG_FILE"
    fi

    if [ -f "$AWS_CREDENTIALS_FILE" ]; then
        creds_profiles=$(get_profiles_from_credentials "$AWS_CREDENTIALS_FILE")
    else
        log_warn "Credentials file not found: $AWS_CREDENTIALS_FILE"
    fi

    local all_profiles
    all_profiles=$(merge_profiles "${config_profiles}${creds_profiles:+$'\n'}$creds_profiles" | tr -d '\r')

    if [ -z "$all_profiles" ]; then
        log_error "No SSO profiles found in $AWS_CONFIG_FILE or $AWS_CREDENTIALS_FILE"
        exit 1
    fi

    local profile_count
    profile_count=$(echo "$all_profiles" | wc -l)

    log_ok "Found $profile_count SSO profile(s)"

    echo ""
    log_info "Validating profiles..."
    echo ""

    local success_count=0
    local failure_count=0

    local tmpfile
    tmpfile=$(mktemp)
    echo "$all_profiles" > "$tmpfile"

    while IFS= read -r profile || [ -n "$profile" ]; do
        [ -z "$profile" ] && continue

        local result
        if result=$(validate_profile "$profile"); then
            success_count=$((success_count + 1))
            local account_id alias
            account_id=$(echo "$result" | cut -d'|' -f1)
            alias=$(echo "$result" | cut -d'|' -f2)
            printf "${GREEN}[OK]${RESET} %-12s | %-20s | %s - authenticated successfully\n" "$account_id" "$alias" "$profile"
        else
            failure_count=$((failure_count + 1))
            export AWS_PROFILE="$profile"
            local account_id
            account_id=$(aws configure get sso_account_id 2>/dev/null) || account_id="<unknown>"
            printf "${RED}[FAIL]${RESET} %-12s | %-20s | %s - failed to authenticate\n" "$account_id" "$profile" "$profile"
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"

    echo ""
    echo "---"
    echo "Validated: $profile_count profile(s)"
    echo -e "Succeeded: ${GREEN}$success_count${RESET}"
    echo -e "Failed:    ${RED}$failure_count${RESET}"

    if [ "$failure_count" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
