#!/bin/bash

set -euo pipefail

# Resolve lib/ui.sh from this script's path, walking parents.
_ui_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_ui_path=""
while [ -n "$_ui_dir" ]; do
    if [ -f "$_ui_dir/lib/ui.sh" ]; then
        _ui_path="$_ui_dir/lib/ui.sh"
        break
    fi
    [ "$_ui_dir" = "/" ] && break
    _ui_dir="$(dirname -- "$_ui_dir")"
done
if [ -z "$_ui_path" ]; then
    printf 'Error: lib/ui.sh not found (copy lib/ with the repo layout)\n' >&2
    exit 1
fi
# shellcheck disable=SC1090,SC1091
. "$_ui_path"

AWS_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
AWS_ENV_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN")

TMPFILE=""
trap 'rm -f "$TMPFILE"' EXIT

CHECK_CONFIG=false
CHECK_ENV=false

BASHRC_FILE="${HOME}/.bashrc"
BASH_PROFILE_FILE="${HOME}/.bash_profile"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Validate local AWS SSO profiles (STS + account alias), or inspect local
config and shell defaults without logging in.

Targets:
  --check-config     Inspect ~/.aws/config for SSO profiles (no login)
  --check-env        Inspect ~/.bashrc and ~/.bash_profile defaults (no login)

Options:
  -q, --quiet        Suppress the banner and non-error status rows
  -h, --help         Show this help message

Examples:
  $0
  $0 --check-config
EOF
}

now() { date +"%Y-%m-%d %H:%M:%S"; }

log_info()  { ui_row "[$(now)] $(ui_color blue)[INFO]$(ui_color reset)  $*"; }
log_ok()    { ui_row "[$(now)] $(ui_color green)[OK]$(ui_color reset)    $*"; }
log_warn()  { ui_always "[$(now)] $(ui_color yellow)[WARN]$(ui_color reset)  $*"; }
log_error() { ui_always "[$(now)] $(ui_color red)[ERROR]$(ui_color reset) $*"; }

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
            ui_always "   - $line"
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

# Print a pure-ASCII panel around one or more rows. Frame width fits the
# longest visible row. Rows may embed real ANSI colors (ui_color) and data
# encoded with ui_esc_data; both are resolved here.
print_panel() {
    ui_is_quiet && return 0
    local rows=("$@")
    local row plain max=0

    for row in "${rows[@]}"; do
        plain=$(ui_visible_plain "$row")
        if [ "${#plain}" -gt "$max" ]; then
            max=${#plain}
        fi
    done

    printf '+%s+\n' "$(_dashes $((max + 2)))" >&2
    for row in "${rows[@]}"; do
        plain=$(ui_visible_plain "$row")
        printf '| ' >&2
        ui_unesc_data "$row" >&2
        printf '%*s |\n' "$((max - ${#plain}))" '' >&2
    done
    printf '+%s+\n' "$(_dashes $((max + 2)))" >&2
}

# Print first AWS_PROFILE value found in a file (stdout); return 0 if found.
_find_aws_profile_in_file() {
    local file="$1"
    [ ! -f "$file" ] && return 1

    local line value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?AWS_PROFILE[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            value="${BASH_REMATCH[2]}"
            # strip inline comments and surrounding quotes/whitespace
            value="${value%%#*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            if [ -n "$value" ]; then
                printf '%s\n' "$value"
                return 0
            fi
        fi
    done < "$file"
    return 1
}

# Return 0 if file appears to source ~/.bashrc (Git Bash login-shell pattern).
_file_sources_bashrc() {
    local file="$1"
    [ ! -f "$file" ] && return 1

    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ (source|\.)[[:space:]]+.*(\.bashrc|BASHRC) ]]; then
            return 0
        fi
    done < "$file"
    return 1
}

run_check_env() {
    log_info "Inspecting shell default profile (AWS_PROFILE)..."
    ui_row ""

    if [ -n "${AWS_PROFILE:-}" ]; then
        log_ok "Current shell: AWS_PROFILE=${AWS_PROFILE}"
    else
        log_info "Current shell: AWS_PROFILE is unset"
    fi

    local bashrc_profile=""
    local bash_profile_profile=""
    local found_in=""

    if [ ! -f "$BASHRC_FILE" ]; then
        log_warn "Missing $BASHRC_FILE (usual place for export AWS_PROFILE=... on Git Bash)"
    elif bashrc_profile=$(_find_aws_profile_in_file "$BASHRC_FILE"); then
        log_ok "$BASHRC_FILE: AWS_PROFILE=${bashrc_profile}"
        found_in="bashrc"
    else
        log_info "$BASHRC_FILE: no AWS_PROFILE assignment found"
    fi

    if [ ! -f "$BASH_PROFILE_FILE" ]; then
        log_info "$BASH_PROFILE_FILE: not present"
    elif bash_profile_profile=$(_find_aws_profile_in_file "$BASH_PROFILE_FILE"); then
        log_ok "$BASH_PROFILE_FILE: AWS_PROFILE=${bash_profile_profile}"
        if [ -z "$found_in" ]; then
            found_in="bash_profile"
        else
            found_in="both"
        fi
    else
        log_info "$BASH_PROFILE_FILE: no AWS_PROFILE assignment found"
    fi

    # Login shells (common in Git Bash) read .bash_profile, not .bashrc, unless sourced.
    if [ -n "$bashrc_profile" ] && [ -f "$BASH_PROFILE_FILE" ] && ! _file_sources_bashrc "$BASH_PROFILE_FILE"; then
        log_warn "$BASH_PROFILE_FILE does not source $BASHRC_FILE (login shells may not load AWS_PROFILE)"
    elif [ -n "$bashrc_profile" ] && [ ! -f "$BASH_PROFILE_FILE" ]; then
        log_warn "No $BASH_PROFILE_FILE; Git Bash login shells may not load $BASHRC_FILE"
    elif [ -n "$bashrc_profile" ] && [ -f "$BASH_PROFILE_FILE" ] && _file_sources_bashrc "$BASH_PROFILE_FILE"; then
        log_ok "$BASH_PROFILE_FILE sources .bashrc"
    fi

    local summary
    case "$found_in" in
        bashrc)
            summary="Shell default: AWS_PROFILE=$(ui_esc_data "$bashrc_profile") (from $(ui_esc_data "$BASHRC_FILE"))"
            ;;
        bash_profile)
            summary="Shell default: AWS_PROFILE=$(ui_esc_data "$bash_profile_profile") (from $(ui_esc_data "$BASH_PROFILE_FILE"))"
            ;;
        both)
            summary="Shell default: AWS_PROFILE set in both rc files (bashrc=$(ui_esc_data "$bashrc_profile"), bash_profile=$(ui_esc_data "$bash_profile_profile"))"
            ;;
        *)
            summary="Shell default: no AWS_PROFILE configured in $(ui_esc_data "$BASHRC_FILE") or $(ui_esc_data "$BASH_PROFILE_FILE")"
            ;;
    esac

    ui_row ""
    print_panel "$summary"
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
    local h_session="SESSION"
    local h_role="ROLE"

    local w_profile=${#h_profile}
    local w_method=${#h_method}
    local w_account=${#h_account}
    local w_session=${#h_session}
    local w_role=${#h_role}

    local display_rows=""
    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local name method session account role session_col role_col
        IFS='|' read -r name method session account role <<< "$row"
        account="${account:-<unset>}"
        if [ "$method" = "session" ]; then
            session_col="${session:-<unset>}"
        else
            session_col="<n/a>"
        fi
        role_col="${role:-<unset>}"
        w_profile=$(_col_width "$w_profile" "$name")
        w_method=$(_col_width "$w_method" "$method")
        w_account=$(_col_width "$w_account" "$account")
        w_session=$(_col_width "$w_session" "$session_col")
        w_role=$(_col_width "$w_role" "$role_col")
        display_rows+="${name}|${method}|${account}|${session_col}|${role_col}"$'\n'
    done <<< "$rows"

    log_ok "Found $profile_count SSO profile(s)"
    ui_out ""
    printf "%-*s | %-*s | %-*s | %-*s | %-*s\n" \
        "$w_profile" "$h_profile" \
        "$w_method" "$h_method" \
        "$w_account" "$h_account" \
        "$w_session" "$h_session" \
        "$w_role" "$h_role"
    printf "%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(_dashes "$w_profile")" \
        "$(_dashes "$w_method")" \
        "$(_dashes "$w_account")" \
        "$(_dashes "$w_session")" \
        "$(_dashes "$w_role")"

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local name method account session_col role_col
        IFS='|' read -r name method account session_col role_col <<< "$row"
        printf "%-*s | %-*s | %-*s | %-*s | %-*s\n" \
            "$w_profile" "$name" \
            "$w_method" "$method" \
            "$w_account" "$account" \
            "$w_session" "$session_col" \
            "$w_role" "$role_col"
    done <<< "$display_rows"

    ui_out ""
    print_panel "Config-only check: $profile_count SSO profile(s) in $(ui_esc_data "$AWS_CONFIG_FILE")"
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

    ui_row ""
    log_info "Validating profiles..."
    ui_row ""

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

        local status account_id alias
        local result
        if result=$(validate_profile "$profile"); then
            success_count=$((success_count + 1))
            status="OK"
            account_id=$(echo "$result" | cut -d'|' -f1)
            alias=$(echo "$result" | cut -d'|' -f2)
        else
            failure_count=$((failure_count + 1))
            status="FAIL"
            account_id="${account_cfg:-<unknown>}"
            [ -z "$account_id" ] && account_id="<unknown>"
            alias="<no-alias>"
        fi

        w_account=$(_col_width "$w_account" "$account_id")
        w_alias=$(_col_width "$w_alias" "$alias")
        w_profile=$(_col_width "$w_profile" "$profile")
        display_rows+="${status}|${account_id}|${alias}|${profile}"$'\n'
    done < "$TMPFILE"

    rm -f "$TMPFILE"
    TMPFILE=""

    while IFS= read -r row || [ -n "$row" ]; do
        [ -z "$row" ] && continue
        local status account_id alias profile
        IFS='|' read -r status account_id alias profile <<< "$row"
        if [ "$status" = "OK" ]; then
            ui_row "$(printf '%s%-6s%s %-*s | %-*s | %-*s' \
                "$(ui_color green)" "[OK]" "$(ui_color reset)" \
                "$w_account" "$account_id" "$w_alias" "$alias" "$w_profile" "$profile")"
        else
            ui_always "$(printf '%s%-6s%s %-*s | %-*s | %-*s' \
                "$(ui_color red)" "[FAIL]" "$(ui_color reset)" \
                "$w_account" "$account_id" "$w_alias" "$alias" "$w_profile" "$profile")"
        fi
    done <<< "$display_rows"

    ui_row ""
    print_panel \
        "Validated: $profile_count profile(s)" \
        "Succeeded: $(ui_color green)$success_count$(ui_color reset)" \
        "Failed:    $(ui_color red)$failure_count$(ui_color reset)"

    if [ "$failure_count" -gt 0 ]; then
        exit 1
    fi
}

# ============================================================================
# GENERATED ASCII ART - DO NOT EDIT BY HAND
# Text: "SSO CHECK" / Font: Slant (FIGlet), 52 cols, pure ASCII
# Source: https://asciified.thelicato.io/api/v2/ascii?text=SSO+CHECK&font=Slant
# Regenerate: curl -s "<url>" | sed 's/[[:space:]]*$//'  ->  paste below
# ============================================================================
print_banner() {
    ui_banner <<'EOF'
   __________ ____     ________  ________________ __
  / ___/ ___// __ \   / ____/ / / / ____/ ____/ //_/
  \__ \\__ \/ / / /  / /   / /_/ / __/ / /   / ,<
 ___/ /__/ / /_/ /  / /___/ __  / /___/ /___/ /| |
/____/____/\____/   \____/_/ /_/_____/\____/_/ |_|

EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-config)
                CHECK_CONFIG=true
                shift
                ;;
            --check-env)
                CHECK_ENV=true
                shift
                ;;
            -q|--quiet)
                ui_quiet
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

    if [ "$CHECK_CONFIG" = true ] && [ "$CHECK_ENV" = true ]; then
        echo "Error: --check-config and --check-env are mutually exclusive" >&2
        usage >&2
        exit 1
    fi

    print_banner

    if [ "$CHECK_CONFIG" = true ]; then
        run_check_config
    elif [ "$CHECK_ENV" = true ]; then
        run_check_env
    else
        run_validate
    fi
}

main "$@"
