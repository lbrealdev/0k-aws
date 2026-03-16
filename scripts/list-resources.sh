#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_dependencies() {
    if ! command -v aws &> /dev/null; then
        error "aws-cli is not installed or not in PATH."
        exit 1
    fi
}

get_account_info() {
    local profile="$1"
    local account region
    
    if [[ -n "$profile" ]]; then
        # Try with specific profile (SSO or credential file)
        account=$(AWS_PROFILE="$profile" aws sts get-caller-identity --query "Account" --output text 2>&1) || {
            error "Failed to authenticate profile '$profile': $account"
            if [[ "$account" == *"SSO"* || "$account" == *"sso"* || "$account" == *"token"* ]]; then
                error "SSO session may be expired. Run: aws sso login --profile $profile"
            fi
            return 1
        }
        region=$(AWS_PROFILE="$profile" aws configure get region 2>/dev/null)
    else
        # Try with current auth (env vars or exported AWS_PROFILE)
        account=$(aws sts get-caller-identity --query "Account" --output text 2>&1) || {
            error "Failed to authenticate: $account"
            if [[ "$account" == *"SSO"* || "$account" == *"sso"* || "$account" == *"token"* ]]; then
                error "SSO session may be expired. Run: aws sso login"
            fi
            return 1
        }
        region=$(aws configure get region 2>/dev/null)
    fi
    
    echo "$account|$region"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Lists all AWS resources in the account using Resource Groups Tagging API.

Optional arguments:
  --region, -r           AWS region (override profile's region)
  --profile, -p          AWS profile name (can be used multiple times)
  --profiles             Comma-separated AWS profile names
  --report               Save output to files instead of stdout
  --report-dir           Custom report directory (default: report/)
  --output, -o           Output format: text or table (default: text)
  --help, -h             Show this help message

Authentication:
  - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
  - SSO profiles: export AWS_PROFILE=<profile> then aws sso login
  - Credential files: ~/.aws/credentials and ~/.aws/config

Examples:
  # List resources using current auth (env vars or exported AWS_PROFILE)
  $0

  # List resources for specific profile
  $0 --profile dev

  # List resources for multiple profiles (switches between them)
  $0 --profiles dev,staging,prod

  # Generate report for multiple profiles
  $0 --profiles dev,staging,prod --report

  # Override region for all profiles
  $0 --profiles dev,staging --region us-east-1

EOF
}

REGION=""
OUTPUT="text"
REPORT=false
REPORT_DIR="report"
PROFILES=()

preprocess_args() {
    local args=("$@")
    if [[ ${#args[@]} -gt 0 ]]; then
        local new_args=()
        for arg in "${args[@]}"; do
            if [[ "$arg" == --*=* ]]; then
                local key="${arg%%=*}"
                local value="${arg#*=}"
                new_args+=("$key" "$value")
            else
                new_args+=("$arg")
            fi
        done
        printf '%s\n' "${new_args[@]}"
    fi
}

set -- $(preprocess_args "$@")

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region|-r)
                if [[ "$1" == --*=* ]]; then
                    REGION="${1#*=}"
                elif [[ -z "${2:-}" || "$2" == --* ]]; then
                    error "Option --region requires a value"
                    exit 1
                else
                    REGION="$2"
                fi
                shift 2
                ;;
        --profile|-p)
            if [[ "$1" == --*=* ]]; then
                PROFILES+=("${1#*=}")
            elif [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --profile requires a value"
                exit 1
            else
                PROFILES+=("$2")
            fi
            shift 2
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
        --output|-o)
            if [[ "$1" == --*=* ]]; then
                OUTPUT="${1#*=}"
            elif [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --output requires a value"
                exit 1
            else
                OUTPUT="$2"
            fi
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    done
}

parse_args "$@"

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "table" ]]; then
    error "Invalid output format: $OUTPUT. Must be 'text' or 'table'"
    exit 1
fi

if [[ ${#PROFILES[@]} -eq 0 ]]; then
    PROFILES+=("")
fi

list_resources() {
    local profile="$1"
    local target_region="$2"
    
    local aws_profile_env=""
    if [[ -n "$profile" ]]; then
        aws_profile_env="AWS_PROFILE=$profile"
    fi
    
    local arns=()
    local pagination_token=""
    local page_count=0
    
    while true; do
        page_count=$((page_count + 1))
        
        local response
        if [[ -n "$pagination_token" ]]; then
            response=$(eval "$aws_profile_env" aws resourcegroupstaggingapi get-resources \
                --region "$target_region" \
                --pagination-token "$pagination_token" \
                --output json \
                --no-cli-pager 2>&1)
        else
            response=$(eval "$aws_profile_env" aws resourcegroupstaggingapi get-resources \
                --region "$target_region" \
                --output json \
                --no-cli-pager 2>&1)
        fi
        
        if [[ $? -ne 0 ]] || [[ "$response" == *"Error"* ]]; then
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
    echo "$page_count"
}

save_report() {
    local profile="$1"
    local account="$2"
    local target_region="$3"
    local resources="$4"
    
    local dir_name
    if [[ -n "$profile" ]]; then
        dir_name="$REPORT_DIR/$profile"
    else
        dir_name="$REPORT_DIR/default"
    fi
    
    mkdir -p "$dir_name"
    
    local output_file="$dir_name/resources.txt"
    echo "$resources" > "$output_file"
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local resource_count
    resource_count=$(echo "$resources" | grep -c . || echo "0")
    
    cat << EOF
profile=$profile
account=$account
region=$target_region
resource_count=$resource_count
output_file=$output_file
EOF
}

generate_summary() {
    local summaries=("$@")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "{"
    echo "  \"generated_at\": \"$timestamp\","
    echo "  \"report_dir\": \"$REPORT_DIR\","
    echo "  \"region\": \"$REGION\","
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
                    echo -n "      \"$key\": $value, "
                else
                    echo -n "      \"$key\": \"$value\", "
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
    check_dependencies
    
    local summaries=()
    local all_resources=""
    local failed_profiles=()
    
    for profile in "${PROFILES[@]}"; do
        local account region
        local account_info
        
        # Get account info - exit on failure
        if ! account_info=$(get_account_info "$profile"); then
            failed_profiles+=("$profile")
            continue
        fi
        
        account=$(echo "$account_info" | cut -d'|' -f1)
        region=$(echo "$account_info" | cut -d'|' -f2)
        
        # Use --region override if provided, otherwise use profile's region
        local target_region="${REGION:-$region}"
        
        if [[ -z "$target_region" ]]; then
            error "No region available for profile '${profile:-default}'. Use --region or configure region in profile."
            failed_profiles+=("$profile")
            continue
        fi
        
        local result
        if ! result=$(list_resources "$profile" "$target_region"); then
            failed_profiles+=("$profile")
            continue
        fi
        
        local resources
        local page_count
        resources=$(echo "$result" | head -n -1)
        page_count=$(echo "$result" | tail -n 1)
        
        local resource_count
        resource_count=$(echo "$resources" | grep -c . || echo "0")
        
        if [[ "$REPORT" == true ]]; then
            local summary
            summary=$(save_report "$profile" "$account" "$target_region" "$resources")
            summaries+=("$summary")
            echo "profile=$profile account=$account region=$target_region resource_count=$resource_count saved_to=$REPORT_DIR/$profile/resources.txt"
        else
            echo "profile=$profile account=$account region=$target_region resource_count=$resource_count"
            echo ""
            echo "$resources"
        fi
    done
    
    # Report any failures
    if [[ ${#failed_profiles[@]} -gt 0 ]]; then
        echo ""
        error "Failed profiles: ${failed_profiles[*]}"
        exit 1
    fi
    
    if [[ "$REPORT" == true && ${#summaries[@]} -gt 0 ]]; then
        echo ""
        local summary_json
        summary_json=$(generate_summary "${summaries[@]}")
        echo "$summary_json" > "$REPORT_DIR/summary.json"
        echo "summary saved to: $REPORT_DIR/summary.json"
    fi
}

main "$@"
