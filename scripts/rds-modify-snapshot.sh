#!/usr/bin/env bash

set -euo pipefail

# Color definitions for better UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
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
Usage: $0 --source-option <source-option-group> --target-option <target-option-group> [OPTIONS]

Modifies RDS DB snapshots by changing their option group based on source option group filter.

Required arguments:
  --source-option    The source option group name to filter snapshots
  --target-option    The target option group name to apply to matching snapshots

Optional arguments:
  --db               Filter by specific DB instance identifier
  --dry-run          Show what would be done without making changes
  --yes, -y          Skip confirmation prompt (use with caution)
  --verbose, -v      Show detailed output for debugging
  --help, -h         Show this help message

Examples:
  # Modify all snapshots from 'old-group' to 'new-group'
  $0 --source-option old-group --target-option new-group

  # Modify snapshots for specific instance only
  $0 --db mydb-instance --source-option old-group --target-option new-group

  # Preview changes without executing
  $0 --source-option old-group --target-option new-group --dry-run

  # Skip confirmation (for automation)
  $0 --source-option old-group --target-option new-group --yes

EOF
}

# Parse arguments
DB_INSTANCE=""
SOURCE_OPTION=""
TARGET_OPTION=""
DRY_RUN=false
SKIP_CONFIRM=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --db)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --db requires a value"
                exit 1
            fi
            DB_INSTANCE="$2"
            shift 2
            ;;
        --source-option)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --source-option requires a value"
                exit 1
            fi
            SOURCE_OPTION="$2"
            shift 2
            ;;
        --target-option)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --target-option requires a value"
                exit 1
            fi
            TARGET_OPTION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
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

# Validate required arguments
if [[ -z "$SOURCE_OPTION" ]]; then
    error "Missing required argument: --source-option"
    usage
    exit 1
fi

if [[ -z "$TARGET_OPTION" ]]; then
    error "Missing required argument: --target-option"
    usage
    exit 1
fi

# Validate source and target are not the same
if [[ "$SOURCE_OPTION" == "$TARGET_OPTION" ]]; then
    error "Source and target option groups cannot be the same: '$SOURCE_OPTION'"
    exit 1
fi

print_banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║       RDS SNAPSHOT BATCH MODIFICATION                  ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
}

main() {
    print_banner
    
    check_dependencies
    check_aws_auth
    
    echo ""
    echo "Configuration:"
    echo "  Source Option Group: $SOURCE_OPTION"
    echo "  Target Option Group: $TARGET_OPTION"
    if [[ -n "$DB_INSTANCE" ]]; then
        echo "  DB Instance Filter:  $DB_INSTANCE"
    fi
    echo ""
    
    if [[ "$DRY_RUN" = true ]]; then
        warning "DRY RUN MODE: No changes will be made"
    fi
    
    echo ""
    info "Finding snapshots with option group '$SOURCE_OPTION'..."
    
    # Build the describe command - using simpler approach for cross-platform compatibility
    local query="DBSnapshots[?OptionGroupName=='$SOURCE_OPTION'].[DBSnapshotIdentifier,Engine,EngineVersion,SnapshotCreateTime]"
    
    # Execute the describe command with proper error handling
    local snapshot_output exit_code
    
    if [[ "$VERBOSE" = true ]]; then
        info "Executing AWS command with query: $query"
    fi
    
    if [[ -n "$DB_INSTANCE" ]]; then
        [[ "$VERBOSE" = true ]] && info "Command: aws rds describe-db-snapshots --db-instance-identifier $DB_INSTANCE --query \"$query\" --output text --no-cli-pager"
        snapshot_output=$(aws rds describe-db-snapshots \
            --db-instance-identifier "$DB_INSTANCE" \
            --query "$query" \
            --output text \
            --no-cli-pager 2>&1) || true
    else
        [[ "$VERBOSE" = true ]] && info "Command: aws rds describe-db-snapshots --query \"$query\" --output text --no-cli-pager"
        snapshot_output=$(aws rds describe-db-snapshots \
            --query "$query" \
            --output text \
            --no-cli-pager 2>&1) || true
    fi
    exit_code=$?
    
    if [[ $exit_code -ne 0 ]] || [[ "$snapshot_output" == *"Error"* ]] || [[ "$snapshot_output" == *"error"* ]]; then
        error "Failed to retrieve snapshots from AWS"
        error "Exit code: $exit_code"
        error "Output: $snapshot_output"
        exit 1
    fi
    
    # Check if we got any results
    if [[ -z "$snapshot_output" || "$snapshot_output" == "None" ]]; then
        warning "No snapshots found with option group '$SOURCE_OPTION'"
        if [[ -n "$DB_INSTANCE" ]]; then
            info "(filtered by DB instance: $DB_INSTANCE)"
        fi
        exit 0
    fi
    
    # Parse snapshot data
    local snapshots=()
    local snapshot_id engine version created
    while IFS=$'\t' read -r snapshot_id engine version created; do
        [[ -n "$snapshot_id" ]] && snapshots+=("$snapshot_id|$engine|$version|$created")
    done <<< "$snapshot_output"
    
    if [[ ${#snapshots[@]} -eq 0 ]]; then
        warning "No valid snapshots found with option group '$SOURCE_OPTION'"
        exit 0
    fi
    
    echo ""
    info "Found ${#snapshots[@]} snapshot(s) to process:"
    echo ""
    printf "%-40s %-12s %-15s %-25s\n" "SNAPSHOT ID" "ENGINE" "VERSION" "CREATED"
    printf "%-40s %-12s %-15s %-25s\n" "----------------------------------------" "------------" "---------------" "-------------------------"
    for snap in "${snapshots[@]}"; do
        IFS='|' read -r snapshot_id engine version created <<< "$snap"
        printf "%-40s %-12s %-15s %-25s\n" "$snapshot_id" "$engine" "$version" "$created"
    done
    echo ""
    
    # Confirmation prompt (unless dry-run or --yes)
    if [[ "$DRY_RUN" = false && "$SKIP_CONFIRM" = false ]]; then
        echo ""
        warning "This will modify ${#snapshots[@]} snapshot(s) to use option group '$TARGET_OPTION'"
        read -p "Do you want to continue? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Operation cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Process each snapshot
    local processed=0
    local failed=0
    
    for snap in "${snapshots[@]}"; do
        IFS='|' read -r SNAPSHOT_ID _ _ _ <<< "$snap"
        processed=$((processed + 1))
        
        echo ""
        info "[$processed/${#snapshots[@]}] Processing: $SNAPSHOT_ID"
        
        if [[ "$DRY_RUN" = true ]]; then
            info "[DRY RUN] Would execute: aws rds modify-db-snapshot --db-snapshot-identifier \"$SNAPSHOT_ID\" --option-group-name \"$TARGET_OPTION\""
        else
            info "  Modifying snapshot to use option group: $TARGET_OPTION"
            if aws rds modify-db-snapshot \
                --db-snapshot-identifier "$SNAPSHOT_ID" \
                --option-group-name "$TARGET_OPTION" \
                --no-cli-pager > /dev/null 2>&1; then
                success "  Successfully modified snapshot: $SNAPSHOT_ID"
            else
                error "  Failed to modify snapshot: $SNAPSHOT_ID"
                failed=$((failed + 1))
            fi
        fi
    done
    
    echo ""
    echo "══════════════════════════════════════════════════════════"
    if [[ "$DRY_RUN" = true ]]; then
        info "DRY RUN COMPLETED"
        info "  Total snapshots found: ${#snapshots[@]}"
        info "  No changes were made"
    else
        if [[ $failed -eq 0 ]]; then
            success "BATCH MODIFICATION COMPLETED SUCCESSFULLY"
        else
            warning "BATCH MODIFICATION COMPLETED WITH ERRORS"
        fi
        info "  Total snapshots found: ${#snapshots[@]}"
        info "  Successfully processed: $((processed - failed))"
        info "  Failed: $failed"
    fi
    echo "══════════════════════════════════════════════════════════"
    echo ""
    
    # Exit with error code if any failed
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"