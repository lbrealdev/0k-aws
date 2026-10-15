#!/usr/bin/env bash

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

info() {
    ui_row "$(ui_color blue)[INFO]$(ui_color reset) $*"
}

error() {
    ui_always "$(ui_color red)[ERROR]$(ui_color reset) $*"
}

check_dependencies() {
    if ! command -v aws &> /dev/null; then
        error "aws-cli is not installed or not in PATH."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq is not installed or not in PATH."
        exit 1
    fi
}

validate_auth() {
    local profile="$1"
    local -a args=(sts get-caller-identity)
    [[ -n "$profile" ]] && args+=(--profile "$profile")
    args+=(--output json)

    local result
    if ! result=$(aws "${args[@]}" 2>&1); then
        if [[ -n "$profile" ]]; then
            error "Profile '$profile' not authenticated"
            error "Run: aws sso login --profile $profile"
        else
            error "Not authenticated. Set AWS credentials or run: aws sso login"
        fi
        return 1
    fi
    
    # Return account ID
    echo "$result" | jq -r '.Account'
}

get_profile_region() {
    local profile="$1"
    local -a args=(configure get region)
    [[ -n "$profile" ]] && args+=(--profile "$profile")
    
    aws "${args[@]}" 2>/dev/null || true
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

List all AWS resources in the account using the Resource Groups Tagging API.

Options:
  -r, --region REGION    AWS region (required if not in the profile)
  -p, --profile NAME     AWS profile name (repeatable)
      --profiles LIST    Comma-separated AWS profile names
      --report           Save output to files instead of stdout
      --report-dir DIR   Report directory (default: report/)
  -o, --output FORMAT    text or table (default: text)
  -q, --quiet            Suppress the header and non-error status rows
  -h, --help             Show this help message

Examples:
  $0 --region us-east-1
  $0 --profiles dev,staging --report
EOF
}

REGION=""
OUTPUT="text"
REPORT=false
REPORT_DIR="report"
PROFILES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --region|--region=*|-r|-r=*)
            if [[ "$1" == --*=* ]]; then
                REGION="${1#*=}"
                shift
            elif [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --region requires a value"
                exit 1
            else
                REGION="$2"
                shift 2
            fi
            ;;
        --profile|--profile=*|-p|-p=*)
            if [[ "$1" == --*=* ]]; then
                PROFILES+=("${1#*=}")
                shift
            elif [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --profile requires a value"
                exit 1
            else
                PROFILES+=("$2")
                shift 2
            fi
            ;;
        --output|--output=*|-o|-o=*)
            if [[ "$1" == --*=* ]]; then
                OUTPUT="${1#*=}"
                shift
            elif [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --output requires a value"
                exit 1
            else
                OUTPUT="$2"
                shift 2
            fi
            ;;
        --profiles)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --profiles requires a value"
                exit 1
            fi
            IFS=',' read -ra ADDR <<< "$2"
            for profile in "${ADDR[@]}"; do
                # Trim leading/trailing whitespace
                profile=$(echo "$profile" | xargs)
                [[ -n "$profile" ]] && PROFILES+=("$profile")
            done
            shift 2
            ;;
        --report)
            REPORT=true
            shift
            ;;
        --report-dir)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --report-dir requires a value"
                exit 1
            fi
            REPORT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -q|--quiet)
            ui_quiet
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "table" ]]; then
    error "Invalid output format: $OUTPUT. Must be 'text' or 'table'"
    exit 1
fi

# If no profiles provided, check AWS_PROFILE env var
if [[ ${#PROFILES[@]} -eq 0 ]]; then
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        PROFILES+=("$AWS_PROFILE")
    else
        PROFILES+=("")  # Empty string means "current auth context"
    fi
fi

list_resources() {
    local profile="$1"
    local target_region="$2"
    
    local -a base_cmd=(aws resourcegroupstaggingapi get-resources)
    [[ -n "$profile" ]] && base_cmd+=(--profile "$profile")
    base_cmd+=(--region "$target_region" --output json --no-cli-pager)
    
    local arns=()
    local pagination_token=""
    local page_count=0
    
    while true; do
        page_count=$((page_count + 1))
        
        local response
        local -a aws_cmd=("${base_cmd[@]}")
        
        if [[ -n "$pagination_token" ]]; then
            aws_cmd+=(--pagination-token "$pagination_token")
        fi
        
        if ! response=$("${aws_cmd[@]}" 2>&1); then
            error "Failed to retrieve resources from AWS"
            error "Response: $response"
            return 1
        fi
        
        local page_arns
        page_arns=$(echo "$response" | jq -r '.ResourceTagMappingList[].ResourceARN // empty' 2>/dev/null) || true
        
        if [[ -n "$page_arns" ]]; then
            while IFS= read -r arn; do
                [[ -n "$arn" ]] && arns+=("$arn")
            done <<< "$page_arns"
        fi
        
        pagination_token=$(echo "$response" | jq -r '.PaginationToken // empty' 2>/dev/null) || true
        
        if [[ -z "$pagination_token" || "$pagination_token" == "null" ]]; then
            break
        fi
    done
    
    printf '%s\n' "${arns[@]}"
}

save_report() {
    local profile="$1"
    local account="$2"
    local target_region="$3"
    local resources="$4"
    
    local dir_name
    local profile_name
    if [[ -n "$profile" ]]; then
        profile_name="$profile"
        dir_name="$REPORT_DIR/$profile"
    else
        profile_name="${AWS_PROFILE:-current}"
        dir_name="$REPORT_DIR/$profile_name"
    fi
    
    mkdir -p "$dir_name"
    
    local output_file="$dir_name/resources.txt"
    echo "$resources" > "$output_file"
    
    local resource_count
    resource_count=$(echo "$resources" | grep -c . || echo "0")
    
    echo "profile=$profile_name account=$account region=$target_region resource_count=$resource_count output_file=$output_file"
}

generate_summary() {
    local summaries=("$@")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "{"
    echo "  \"generated_at\": \"$timestamp\","
    echo "  \"report_dir\": \"$REPORT_DIR\","
    echo "  \"profiles\": ["
    
    local first=true
    for summary in "${summaries[@]}"; do
        if [[ -n "$summary" ]]; then
            if [[ "$first" == true ]]; then
                first=false
            else
                echo ","
            fi
            echo "    {"
            
            while IFS='=' read -r key value; do
                [[ -z "$key" ]] && continue
                if [[ "$key" == "resource_count" || "$key" == "account" ]]; then
                    echo -n "      \"$key\": $value"
                else
                    echo -n "      \"$key\": \"$value\""
                fi
                
                # Add comma unless it's the last field
                if [[ "$key" != "output_file" ]]; then
                    echo ","
                fi
            done <<< "$summary"
            
            echo -n "    }"
        fi
    done
    
    echo ""
    echo "  ]"
    echo "}"
}

main() {
    ui_header "list-resources: account resources via Resource Groups Tagging API"
    check_dependencies
    
    local summaries=()
    
    for profile in "${PROFILES[@]}"; do
        local account region target_region
        
        # Validate auth - exit on failure
        if ! account=$(validate_auth "$profile"); then
            exit 1
        fi
        
        # Get region from profile or use --region override
        region=$(get_profile_region "$profile")
        target_region="${REGION:-$region}"
        
        # Fail if no region available
        if [[ -z "$target_region" ]]; then
            local display_profile="${profile:-${AWS_PROFILE:-current}}"
            error "No region configured for profile '$display_profile'. Use --region flag."
            exit 1
        fi
        
        local resources
        if ! resources=$(list_resources "$profile" "$target_region"); then
            exit 1
        fi
        
        local resource_count
        resource_count=$(echo "$resources" | grep -c . || echo "0")
        
        local display_profile="${profile:-${AWS_PROFILE:-current}}"
        
        if [[ "$REPORT" == true ]]; then
            local summary
            summary=$(save_report "$profile" "$account" "$target_region" "$resources")
            summaries+=("$summary")
            echo "profile=$display_profile account=$account region=$target_region resource_count=$resource_count saved_to=$REPORT_DIR/$display_profile/resources.txt"
        else
            echo "profile=$display_profile account=$account region=$target_region resource_count=$resource_count"
            echo ""
            echo "$resources"
        fi
    done
    
    if [[ "$REPORT" == true && ${#summaries[@]} -gt 0 ]]; then
        echo ""
        local summary_json
        summary_json=$(generate_summary "${summaries[@]}")
        echo "$summary_json" > "$REPORT_DIR/summary.json"
        echo "summary saved to: $REPORT_DIR/summary.json"
    fi
}

main "$@"
