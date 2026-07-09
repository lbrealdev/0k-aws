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

aws_cmd() {
    # shellcheck disable=SC2086
    aws "$@" ${PROFILE_ARG} ${REGION_ARG} --no-cli-pager
}

check_aws_auth() {
    local region
    if ! ACCOUNT_ID=$(aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
        error "Invalid or missing AWS credentials/access keys."
        if [[ -n "$PROFILE" ]]; then
            error "Try: aws sso login --profile $PROFILE"
        else
            error "Set AWS credentials or run: aws sso login"
        fi
        exit 1
    fi

    if [[ -n "$REGION" ]]; then
        region="$REGION"
    else
        region=$(aws configure get region ${PROFILE:+--profile "$PROFILE"} 2>/dev/null || echo "not set")
    fi

    info "AWS Account: $ACCOUNT_ID"
    info "AWS Region:  $region"
    if [[ -n "$PROFILE" ]]; then
        info "AWS Profile: $PROFILE"
    fi
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Read-only inventory of EC2-related backup and elimination resources:
  instances, volumes, snapshots, owned AMIs, DLM policies, and AWS Backup recovery points.

Optional arguments:
  --region, -r       AWS region
  --profile, -p      AWS profile name
  --report           Save section outputs under a timestamped report directory
  --report-dir       Custom report directory (default: report/ec2-backup-inventory-<timestamp>)
  --skip-backup      Skip AWS Backup vault/recovery-point enumeration
  --skip-dlm         Skip Data Lifecycle Manager policies
  --help, -h         Show this help message

Examples:
  $0 --region us-east-1
  $0 --profile prod --report
  $0 --profile prod --region us-west-2 --skip-backup

EOF
}

PROFILE=""
REGION=""
REPORT=false
REPORT_DIR=""
SKIP_BACKUP=false
SKIP_DLM=false
ACCOUNT_ID=""
PROFILE_ARG=""
REGION_ARG=""
REPORT_PATH=""

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
        --profile|-p)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --profile requires a value"
                exit 1
            fi
            PROFILE="$2"
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
            REPORT=true
            shift 2
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --skip-dlm)
            SKIP_DLM=true
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

section() {
    local title="$1"
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo " $title"
    echo "══════════════════════════════════════════════════════════"
}

write_report() {
    local filename="$1"
    local content="$2"

    if [[ "$REPORT" = true ]]; then
        printf "%s\n" "$content" > "$REPORT_PATH/$filename"
        info "Wrote $REPORT_PATH/$filename"
    fi
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

print_or_empty() {
    local label="$1"
    local content="$2"
    local filename

    filename="$(slugify "$label").txt"

    if [[ -z "${content//[[:space:]]/}" || "$content" == "None" ]]; then
        warning "No $label found"
        write_report "$filename" "No $label found"
        return
    fi

    echo "$content"
    write_report "$filename" "$content"
}

inventory_instances() {
    section "EC2 Instances"
    local output
    output=$(aws_cmd ec2 describe-instances \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down,terminated" \
        --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name']|[0].Value,InstanceType,State.Name,LaunchTime,Placement.AvailabilityZone]" \
        --output table 2>&1) || true

    if [[ "$output" == *"error"* || "$output" == *"Error"* || "$output" == *"AccessDenied"* ]]; then
        error "Failed to list instances: $output"
        return
    fi
    print_or_empty "instances" "$output"
}

inventory_volumes() {
    section "EBS Volumes"
    local output
    output=$(aws_cmd ec2 describe-volumes \
        --query "Volumes[*].[VolumeId,Size,VolumeType,State,AvailabilityZone,Attachments[0].InstanceId,Attachments[0].Device,Attachments[0].DeleteOnTermination]" \
        --output table 2>&1) || true

    if [[ "$output" == *"error"* || "$output" == *"Error"* || "$output" == *"AccessDenied"* ]]; then
        error "Failed to list volumes: $output"
        return
    fi
    print_or_empty "volumes" "$output"

    section "Unattached EBS Volumes"
    local available
    available=$(aws_cmd ec2 describe-volumes \
        --filters "Name=status,Values=available" \
        --query "Volumes[*].[VolumeId,Size,VolumeType,AvailabilityZone,CreateTime]" \
        --output table 2>&1) || true
    print_or_empty "unattached volumes" "$available"
}

inventory_snapshots() {
    section "EBS Snapshots (account-owned)"
    local output
    output=$(aws_cmd ec2 describe-snapshots \
        --owner-ids "$ACCOUNT_ID" \
        --query "sort_by(Snapshots[*].{ID:SnapshotId,Volume:VolumeId,State:State,Start:StartTime,Size:VolumeSize,Name:Tags[?Key=='Name']|[0].Value,Desc:Description}, &Start)" \
        --output table 2>&1) || true

    if [[ "$output" == *"error"* || "$output" == *"Error"* || "$output" == *"AccessDenied"* ]]; then
        error "Failed to list snapshots: $output"
        return
    fi
    print_or_empty "snapshots" "$output"
}

inventory_amis() {
    section "Owned AMIs"
    local output
    output=$(aws_cmd ec2 describe-images \
        --owners "$ACCOUNT_ID" \
        --query "sort_by(Images[*].{AMI:Name,ID:ImageId,Date:CreationDate,State:State,Root:RootDeviceType,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}, &Date)" \
        --output table 2>&1) || true

    if [[ "$output" == *"error"* || "$output" == *"Error"* || "$output" == *"AccessDenied"* ]]; then
        error "Failed to list AMIs: $output"
        return
    fi
    print_or_empty "amis" "$output"

    section "AMI Backing Snapshots"
    local mapping
    mapping=$(aws_cmd ec2 describe-images \
        --owners "$ACCOUNT_ID" \
        --query "Images[*].[ImageId,Name,BlockDeviceMappings[*].Ebs.SnapshotId]" \
        --output text 2>&1) || true

    if [[ "$mapping" == *"error"* || "$mapping" == *"Error"* || "$mapping" == *"AccessDenied"* ]]; then
        error "Failed to list AMI snapshot mappings: $mapping"
        return
    fi
    print_or_empty "ami snapshot mappings" "$mapping"
}

inventory_dlm() {
    if [[ "$SKIP_DLM" = true ]]; then
        info "Skipping DLM (--skip-dlm)"
        return
    fi

    section "DLM Lifecycle Policies"
    local output
    if ! output=$(aws_cmd dlm get-lifecycle-policies \
        --query "Policies[*].[PolicyId,Description,State,PolicyType,DefaultPolicy]" \
        --output table 2>&1); then
        warning "Could not list DLM policies (permissions or service unavailable)"
        warning "$output"
        write_report "dlm-policies.txt" "Could not list DLM policies: $output"
        return
    fi
    print_or_empty "dlm policies" "$output"
}

inventory_backup() {
    if [[ "$SKIP_BACKUP" = true ]]; then
        info "Skipping AWS Backup (--skip-backup)"
        return
    fi

    section "AWS Backup Vaults"
    local vaults vault_names
    if ! vaults=$(aws_cmd backup list-backup-vaults \
        --query "BackupVaultList[*].[BackupVaultName,EncryptionKeyArn,NumberOfRecoveryPoints]" \
        --output table 2>&1); then
        warning "Could not list AWS Backup vaults (permissions or service unavailable)"
        warning "$vaults"
        write_report "backup-vaults.txt" "Could not list AWS Backup vaults: $vaults"
        return
    fi
    print_or_empty "backup vaults" "$vaults"

    vault_names=$(aws_cmd backup list-backup-vaults \
        --query "BackupVaultList[*].BackupVaultName" \
        --output text 2>/dev/null || true)

    section "AWS Backup Recovery Points (EC2/EBS)"
    if [[ -z "${vault_names//[[:space:]]/}" ]]; then
        warning "No backup vaults found"
        write_report "backup-recovery-points.txt" "No backup vaults found"
        return
    fi

    local combined="" vault points
    for vault in $vault_names; do
        points=$(aws_cmd backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$vault" \
            --query "RecoveryPoints[?contains(ResourceArn, 'ec2') || contains(ResourceArn, 'ebs')].[RecoveryPointArn,ResourceArn,CreationDate,Status,CompletionDate]" \
            --output text 2>/dev/null || true)
        if [[ -n "${points//[[:space:]]/}" && "$points" != "None" ]]; then
            combined+="Vault: $vault"$'\n'"$points"$'\n\n'
        fi
    done

    print_or_empty "backup recovery points" "$combined"

    section "AWS Backup Plans"
    local plans
    if ! plans=$(aws_cmd backup list-backup-plans \
        --query "BackupPlansList[*].[BackupPlanName,BackupPlanId,LastExecutionDate]" \
        --output table 2>&1); then
        warning "Could not list AWS Backup plans"
        warning "$plans"
        write_report "backup-plans.txt" "Could not list AWS Backup plans: $plans"
        return
    fi
    print_or_empty "backup plans" "$plans"
}

print_banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║       EC2 BACKUP / ELIMINATION INVENTORY               ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
}

main() {
    print_banner
    check_dependencies

    [[ -n "$PROFILE" ]] && PROFILE_ARG="--profile $PROFILE"
    [[ -n "$REGION" ]] && REGION_ARG="--region $REGION"

    check_aws_auth

    if [[ "$REPORT" = true ]]; then
        if [[ -z "$REPORT_DIR" ]]; then
            REPORT_DIR="report/ec2-backup-inventory-$(date +%Y%m%d-%H%M%S)"
        fi
        REPORT_PATH="$REPORT_DIR"
        mkdir -p "$REPORT_PATH"
        info "Report directory: $REPORT_PATH"
    fi

    inventory_instances
    inventory_volumes
    inventory_snapshots
    inventory_amis
    inventory_dlm
    inventory_backup

    echo ""
    success "Inventory complete (read-only; no changes were made)"
    info "See ec2/ec2-elimination.md for the elimination checklist"
    echo ""
}

main "$@"
