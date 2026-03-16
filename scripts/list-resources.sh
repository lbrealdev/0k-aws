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

check_aws_auth() {
    local account region
    if ! account=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
        error "Invalid or missing AWS credentials/access keys."
        exit 1
    fi
    
    region=$(aws configure get region 2>/dev/null || echo "not set")
    info "AWS Account: $account"
    info "AWS Region: $region"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Lists all AWS resources in the account using Resource Groups Tagging API.

Optional arguments:
  --region, -r       AWS region (default: from AWS config)
  --output, -o       Output format: text or table (default: text)
  --help, -h         Show this help message

Examples:
  # List all resources in default region
  $0

  # List all resources in specific region
  $0 --region us-east-1

  # List resources in table format
  $0 --output table

EOF
}

REGION=""
OUTPUT="text"

while [[ $# -gt 0 ]]; do
    case $1 in
        --region|-r)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --region requires a value"
                exit 1
            fi
            REGION="$2"
            shift 2
            ;;
        --output|-o)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --output requires a value"
                exit 1
            fi
            OUTPUT="$2"
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

if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region 2>/dev/null) || true
fi

if [[ -z "$REGION" ]]; then
    error "No region specified. Use --region or configure AWS region."
    exit 1
fi

if [[ "$OUTPUT" != "text" && "$OUTPUT" != "table" ]]; then
    error "Invalid output format: $OUTPUT. Must be 'text' or 'table'"
    exit 1
fi

print_banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║          AWS RESOURCE LISTING                          ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
}

list_resources() {
    local arns=()
    local pagination_token=""
    local page_count=0
    
    info "Fetching resources from region: $REGION"
    echo ""
    
    while true; do
        page_count=$((page_count + 1))
        
        local response
        if [[ -n "$pagination_token" ]]; then
            response=$(aws resourcegroupstaggingapi get-resources \
                --region "$REGION" \
                --pagination-token "$pagination_token" \
                --output json \
                --no-cli-pager 2>&1)
        else
            response=$(aws resourcegroupstaggingapi get-resources \
                --region "$REGION" \
                --output json \
                --no-cli-pager 2>&1)
        fi
        
        if [[ $? -ne 0 ]] || [[ "$response" == *"Error"* ]]; then
            error "Failed to retrieve resources from AWS"
            error "Response: $response"
            exit 1
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
        
        info "Fetching page $page_count..."
    done
    
    if [[ ${#arns[@]} -eq 0 ]]; then
        info "No resources found in region: $REGION"
        exit 0
    fi
    
    info "Found ${#arns[@]} resource(s) across $page_count page(s)"
    echo ""
    
    if [[ "$OUTPUT" == "table" ]]; then
        printf "%-80s\n" "ARN"
        printf "%-80s\n" "--------------------------------------------------------------------------------"
        for arn in "${arns[@]}"; do
            printf "%-80s\n" "$arn"
        done
    else
        for arn in "${arns[@]}"; do
            echo "$arn"
        done
    fi
}

main() {
    print_banner
    
    check_dependencies
    check_aws_auth
    
    echo ""
    echo "Configuration:"
    echo "  Region:  $REGION"
    echo "  Output:  $OUTPUT"
    echo ""
    
    list_resources
}

main "$@"
