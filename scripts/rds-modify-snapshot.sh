#!/usr/bin/env bash

set -euo pipefail

# Logging function with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_dependencies() {
    if ! command -v aws > /dev/null; then
        log "Error: aws-cli is not installed or not in PATH."
        exit 1
    fi
}

check_aws_auth() {
    if ! ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
        log "Error: invalid or missing AWS credentials/access keys."
        exit 1
    else
        AWS_ACCOUNT="$ACCOUNT"
        AWS_REGION=$(aws configure get region)
        
        log "AWS ACCOUNT: $AWS_ACCOUNT"
        log "AWS REGION: ${AWS_REGION:-not set}"
    fi
}

usage() {
    echo "Usage: $0 --db <db-instance-identifier> --source-option <option-group-name> --target-option <option-group-name> [--dry-run]"
    echo ""
    echo "Modifies RDS DB snapshots by changing their option group based on source option group filter."
    echo ""
    echo "Required arguments:"
    echo "  --db               The DB instance identifier to filter snapshots (optional)"
    echo "  --source-option    The source option group name to filter snapshots"
    echo "  --target-option    The target option group name to apply to matching snapshots"
    echo ""
    echo "Optional arguments:"
    echo "  --dry-run          Show what would be done without making changes"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Modify all snapshots for instance 'mydb' from 'old-opt-group' to 'new-opt-group'"
    echo "  $0 --db mydb --source-option old-opt-group --target-option new-opt-group"
    echo ""
    echo "  # Modify all snapshots (any instance) from 'old-opt-group' to 'new-opt-group'"
    echo "  $0 --source-option old-opt-group --target-option new-opt-group"
    echo ""
    echo "  # Dry run to see what would be modified"
    echo "  $0 --db mydb --source-option old-opt-group --target-option new-opt-group --dry-run"
}

# Parse arguments
DB_INSTANCE=""
SOURCE_OPTION=""
TARGET_OPTION=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --db)
            DB_INSTANCE="$2"
            shift 2
            ;;
        --source-option)
            SOURCE_OPTION="$2"
            shift 2
            ;;
        --target-option)
            TARGET_OPTION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE_OPTION" ]]; then
    log "Error: --source-option is required"
    usage
    exit 1
fi

if [[ -z "$TARGET_OPTION" ]]; then
    log "Error: --target-option is required"
    usage
    exit 1
fi

main() {
    log "################################"
    log "#   RDS SNAPSHOT BATCH MODIFICATION  #"
    log "################################"
    log ""
    
    check_dependencies
    check_aws_auth
    
    # Build the describe command
    DESCRIBE_CMD="aws rds describe-db-snapshots"
    
    if [[ -n "$DB_INSTANCE" ]]; then
        DESCRIBE_CMD+=" --db-instance-identifier \"$DB_INSTANCE\""
        log "Filtering by DB instance: $DB_INSTANCE"
    fi
    
    DESCRIBE_CMD+=" --query \"DBSnapshots[?OptionGroupName=='$SOURCE_OPTION'].DBSnapshotIdentifier\" --output text"
    
    log "Source option group: $SOURCE_OPTION"
    log "Target option group: $TARGET_OPTION"
    
    if [[ "$DRY_RUN" = true ]]; then
        log "DRY RUN MODE: No changes will be made"
    fi
    
    log ""
    
    # Execute the describe command to get matching snapshot IDs
    log "Finding snapshots with option group '$SOURCE_OPTION'..."
    
    # Use a temporary variable to capture output and handle potential errors
    SNAPSHOT_OUTPUT=$(eval "$DESCRIBE_CMD" 2>/dev/null || true)
    
    # Check if we got any results
    if [[ -z "$SNAPSHOT_OUTPUT" || "$SNAPSHOT_OUTPUT" == "None" ]]; then
        log "No snapshots found with option group '$SOURCE_OPTION'"
        if [[ -n "$DB_INSTANCE" ]]; then
            log "  (filtered by DB instance: $DB_INSTANCE)"
        fi
        exit 0
    fi
    
    # Convert output to array (handles multiple lines/spaces)
    IFS=$'\n' read -rd '' -a SNAPSHOT_IDS <<<"$SNAPSHOT_OUTPUT"
    # Remove empty elements
    SNAPSHOT_IDS=("${SNAPSHOT_IDS[@]//$'\n'}")
    SNAPSHOT_IDS=($(for id in "${SNAPSHOT_IDS[@]}"; do [[ -n "$id" ]] && echo "$id"; done))
    
    if [[ ${#SNAPSHOT_IDS[@]} -eq 0 ]]; then
        log "No valid snapshots found with option group '$SOURCE_OPTION'"
        exit 0
    fi
    
    log "Found ${#SNAPSHOT_IDS[@]} snapshot(s) to process:"
    for snap in "${SNAPSHOT_IDS[@]}"; do
        log "  - $snap"
    done
    log ""
    
    # Process each snapshot
    local processed=0
    local failed=0
    
    for SNAPSHOT_ID in "${SNAPSHOT_IDS[@]}"; do
        processed=$((processed + 1))
        log "[$processed/${#SNAPSHOT_IDS[@]}] Processing snapshot: $SNAPSHOT_ID"
        
        if [[ "$DRY_RUN" = true ]]; then
            log "  [DRY RUN] Would execute: aws rds modify-db-snapshot --db-snapshot-identifier \"$SNAPSHOT_ID\" --option-group-name \"$TARGET_OPTION\""
        else
            log "  Modifying snapshot to use option group: $TARGET_OPTION"
            aws rds modify-db-snapshot \
                --db-snapshot-identifier "$SNAPSHOT_ID" \
                --option-group-name "$TARGET_OPTION"
            log "  Successfully modified snapshot: $SNAPSHOT_ID"
        fi
    done
    
    log ""
    log "Processing complete:"
    log "  Total snapshots found: ${#SNAPSHOT_IDS[@]}"
    log "  Successfully processed: $processed"
    if [[ "$DRY_RUN" = false ]]; then
        log "  Failed: $failed"
    fi
    
    if [[ "$DRY_RUN" = true ]]; then
        log "DRY RUN COMPLETED: No changes were made"
    else
        log "BATCH MODIFICATION COMPLETED"
    fi
}

main