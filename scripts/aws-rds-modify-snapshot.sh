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
    printf 'Error: lib/ui.sh not found (copy scripts/lib next to the script)\n' >&2
    exit 1
fi
# shellcheck disable=SC1090,SC1091
. "$_ui_path"

# Output functions (status rows go to stderr; ui_row obeys --quiet)
info() {
    ui_row "$(ui_color blue)[INFO]$(ui_color reset) $1"
}

success() {
    ui_row "$(ui_color green)[SUCCESS]$(ui_color reset) $1"
}

warning() {
    ui_always "$(ui_color yellow)[WARNING]$(ui_color reset) $1"
}

error() {
    ui_always "$(ui_color red)[ERROR]$(ui_color reset) $1"
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

Change the option group of RDS DB snapshots that match a source group.

Required:
      --source-option NAME  Source option group to match
      --target-option NAME  Option group to apply

Options:
      --db NAME             Limit to one DB instance
      --snapshot-type T     awsbackup (default) or manual
      --dry-run             Show the plan; change nothing
  -y, --yes                 Skip confirmation prompt
  -v, --verbose             Show detailed output
  -q, --quiet               Suppress the banner and non-error status rows
  -h, --help                Show this help message

Examples:
  $0 --source-option a --target-option b --dry-run
  $0 --source-option a --target-option b --yes
EOF
}

# Parse arguments
DB_INSTANCE=""
SOURCE_OPTION=""
TARGET_OPTION=""
SNAPSHOT_TYPE="awsbackup"
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
        --snapshot-type)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --snapshot-type requires a value"
                exit 1
            fi
            SNAPSHOT_TYPE="$2"
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
        -q|--quiet)
            ui_quiet
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE_OPTION" ]]; then
    error "Missing required argument: --source-option"
    usage >&2
    exit 1
fi

if [[ -z "$TARGET_OPTION" ]]; then
    error "Missing required argument: --target-option"
    usage >&2
    exit 1
fi

# Validate source and target are not the same
if [[ "$SOURCE_OPTION" == "$TARGET_OPTION" ]]; then
    error "Source and target option groups cannot be the same: '$SOURCE_OPTION'"
    exit 1
fi

# Validate snapshot type
if [[ "$SNAPSHOT_TYPE" != "awsbackup" && "$SNAPSHOT_TYPE" != "manual" ]]; then
    error "Invalid snapshot type: $SNAPSHOT_TYPE. Must be 'awsbackup' or 'manual'"
    usage >&2
    exit 1
fi

print_banner() {
    ui_banner <<'EOF'

╔════════════════════════════════════════════════════════╗
║       RDS SNAPSHOT BATCH MODIFICATION                  ║
╚════════════════════════════════════════════════════════╝

EOF
}

main() {
    print_banner
    
    check_dependencies
    check_aws_auth
    
    ui_row ""
    info "Configuration:"
    info "  Source Option Group: $SOURCE_OPTION"
    info "  Target Option Group: $TARGET_OPTION"
    info "  Snapshot Type:       $SNAPSHOT_TYPE"
    if [[ -n "$DB_INSTANCE" ]]; then
        info "  DB Instance Filter:  $DB_INSTANCE"
    fi
    ui_row ""
    
    if [[ "$DRY_RUN" = true ]]; then
        warning "DRY RUN MODE: No changes will be made"
    fi
    
    ui_row ""
    info "Finding '$SNAPSHOT_TYPE' snapshots with option group '$SOURCE_OPTION'..."
    
    # Build the describe command - using simpler approach for cross-platform compatibility
    local query="DBSnapshots[?OptionGroupName=='$SOURCE_OPTION'].[DBSnapshotIdentifier,Engine,EngineVersion,SnapshotCreateTime]"
    
    # Execute the describe command with proper error handling
    local snapshot_output exit_code
    
    if [[ "$VERBOSE" = true ]]; then
        info "Executing AWS command with query: $query"
    fi
    
    if [[ -n "$DB_INSTANCE" ]]; then
        [[ "$VERBOSE" = true ]] && info "Command: aws rds describe-db-snapshots --snapshot-type $SNAPSHOT_TYPE --db-instance-identifier $DB_INSTANCE --query \"$query\" --output text --no-cli-pager"
        snapshot_output=$(aws rds describe-db-snapshots \
            --snapshot-type "$SNAPSHOT_TYPE" \
            --db-instance-identifier "$DB_INSTANCE" \
            --query "$query" \
            --output text \
            --no-cli-pager 2>&1) || true
    else
        [[ "$VERBOSE" = true ]] && info "Command: aws rds describe-db-snapshots --snapshot-type $SNAPSHOT_TYPE --query \"$query\" --output text --no-cli-pager"
        snapshot_output=$(aws rds describe-db-snapshots \
            --snapshot-type "$SNAPSHOT_TYPE" \
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
        warning "No '$SNAPSHOT_TYPE' snapshots found with option group '$SOURCE_OPTION'"
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
    
    ui_row ""
    info "Found ${#snapshots[@]} snapshot(s) to process:"
    ui_row ""
    printf "%-40s %-12s %-15s %-25s\n" "SNAPSHOT ID" "ENGINE" "VERSION" "CREATED"
    printf "%-40s %-12s %-15s %-25s\n" "----------------------------------------" "------------" "---------------" "-------------------------"
    for snap in "${snapshots[@]}"; do
        IFS='|' read -r snapshot_id engine version created <<< "$snap"
        printf "%-40s %-12s %-15s %-25s\n" "$snapshot_id" "$engine" "$version" "$created"
    done
    ui_row ""
    
    # Confirmation prompt (unless dry-run or --yes)
    if [[ "$DRY_RUN" = false && "$SKIP_CONFIRM" = false ]]; then
        ui_row ""
        warning "This will modify ${#snapshots[@]} snapshot(s) to use option group '$TARGET_OPTION'"
        read -p "Do you want to continue? (y/N): " -n 1 -r
        ui_row ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Operation cancelled by user"
            exit 0
        fi
        ui_row ""
    fi
    
    # Process each snapshot
    local processed=0
    local failed=0
    
    for snap in "${snapshots[@]}"; do
        IFS='|' read -r SNAPSHOT_ID _ _ _ <<< "$snap"
        processed=$((processed + 1))
        
        ui_row ""
        info "[$processed/${#snapshots[@]}] Processing: $SNAPSHOT_ID"
        
        if [[ "$DRY_RUN" = true ]]; then
            ui_out "[DRY RUN] Would execute: aws rds modify-db-snapshot --db-snapshot-identifier \"$SNAPSHOT_ID\" --option-group-name \"$TARGET_OPTION\""
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
    
    ui_row ""
    ui_row "══════════════════════════════════════════════════════════"
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
    ui_row "══════════════════════════════════════════════════════════"
    ui_row ""
    
    # Exit with error code if any failed
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
