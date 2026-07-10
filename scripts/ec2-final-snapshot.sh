#!/usr/bin/env bash

set -euo pipefail

# Platform note: Git Bash / MSYS may emit CRLF from external commands.
strip_cr() {
    printf '%s' "$1" | tr -d '\r'
}

sanitize_stream() {
    tr -d '\r'
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

timestamp() {
    date '+%H:%M:%S'
}

info() {
    echo -e "${BLUE}[$(timestamp)] [INFO]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[$(timestamp)] [SUCCESS]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[$(timestamp)] [WARNING]${NC} $1" >&2
}

error() {
    echo -e "${RED}[$(timestamp)] [ERROR]${NC} $1" >&2
}

DEFAULT_PURPOSE="manual-final-snapshot"

PROFILE=""
REGION=""
DRY_RUN=false
WAIT_SNAPSHOTS=false
SKIP_CONFIRM=false
REPORT_DIR=""
ACCOUNT_ID=""
EFFECTIVE_REGION=""
PROFILE_ARG=""
REGION_ARG=""
REPORT_PATH=""
INSTANCE_IDS=()
# Parallel arrays for user tags (bash 3–compatible)
TAG_KEYS=()
TAG_VALUES=()
RESULT_FILES=()

usage() {
    cat << EOF
Usage: $0 --instance <instance-id>[,<instance-id>...] [OPTIONS]

Create crash-consistent EBS snapshots for attached volumes on live EC2 instances
(aws ec2 create-snapshots). Copies volume tags and adds Purpose=${DEFAULT_PURPOSE}.

Does NOT terminate or delete resources. Instance must exist.

Required arguments:
  --instance, -i     One or more instance IDs (repeatable or comma-separated)

Optional arguments:
  --region, -r       AWS region
  --profile, -p      AWS profile name
  --tag Key=Value    Extra snapshot tag (repeatable; cannot override Purpose)
  --dry-run          Preview volumes/tags; do not create snapshots
  --wait             Wait until each snapshot completes
  --yes, -y          Skip confirmation prompt
  --report-dir       Report directory (default: report/ec2-final-snapshot-<timestamp>)
  --help, -h         Show this help message

Examples:
  $0 -i i-0123456789abcdef0 --region us-east-1 --dry-run
  $0 -i i-aaa --profile prod --tag ChangeTicket=CHG123
  $0 -i i-aaa -i i-bbb --wait --yes

EOF
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

aws_cmd() {
    # shellcheck disable=SC2086
    aws "$@" ${PROFILE_ARG} ${REGION_ARG} --no-cli-pager
}

aws_json() {
    local output
    if ! output=$(aws_cmd "$@" --output json 2>&1); then
        error "AWS command failed: aws $*"
        error "$output"
        return 1
    fi
    printf '%s' "$output" | sanitize_stream
}

aws_json_quiet() {
    local output
    if ! output=$(aws_cmd "$@" --output json 2>/dev/null); then
        return 1
    fi
    printf '%s' "$output" | sanitize_stream
}

check_aws_auth() {
    local region identity
    if ! identity=$(aws_json sts get-caller-identity); then
        error "Invalid or missing AWS credentials/access keys."
        if [[ -n "$PROFILE" ]]; then
            error "Try: aws sso login --profile $PROFILE"
        else
            error "Set AWS credentials or run: aws sso login"
        fi
        exit 1
    fi

    ACCOUNT_ID="$(printf '%s' "$identity" | jq -r '.Account' | tr -d '\r')"

    if [[ -n "$REGION" ]]; then
        region="$REGION"
    else
        region=$(aws configure get region ${PROFILE:+--profile "$PROFILE"} 2>/dev/null | tr -d '\r' || true)
        [[ -z "$region" ]] && region="not set"
    fi
    EFFECTIVE_REGION="$region"

    info "AWS Account: $ACCOUNT_ID"
    info "AWS Region:  $EFFECTIVE_REGION"
    if [[ -n "$PROFILE" ]]; then
        info "AWS Profile: $PROFILE"
    fi
}

add_instance_ids() {
    local raw="$1"
    local part cleaned
    raw="$(strip_cr "$raw")"
    IFS=',' read -ra parts <<< "$raw"
    for part in "${parts[@]}"; do
        cleaned="$(strip_cr "$part")"
        cleaned="${cleaned//[[:space:]]/}"
        [[ -z "$cleaned" ]] && continue
        INSTANCE_IDS+=("$cleaned")
    done
}

tag_key_exists() {
    local needle="$1"
    local k
    for k in "${TAG_KEYS[@]+"${TAG_KEYS[@]}"}"; do
        if [[ "$k" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

add_tag() {
    local raw="$1"
    local key value
    raw="$(strip_cr "$raw")"
    if [[ "$raw" != *=* ]]; then
        error "Invalid --tag value '$raw' (expected Key=Value)"
        exit 1
    fi
    key="${raw%%=*}"
    value="${raw#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    if [[ -z "$key" || -z "$value" ]]; then
        error "Invalid --tag value '$raw' (Key and Value must be non-empty)"
        exit 1
    fi
    if [[ "$key" == "Purpose" ]]; then
        error "Cannot override Purpose via --tag (fixed to ${DEFAULT_PURPOSE})"
        exit 1
    fi
    if tag_key_exists "$key"; then
        error "Duplicate --tag key: $key"
        exit 1
    fi
    TAG_KEYS+=("$key")
    TAG_VALUES+=("$value")
}

dedupe_instances() {
    local -a unique=()
    local id seen
    for id in "${INSTANCE_IDS[@]}"; do
        seen=false
        for existing in "${unique[@]+"${unique[@]}"}"; do
            if [[ "$existing" == "$id" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == false ]] && unique+=("$id")
    done
    INSTANCE_IDS=("${unique[@]}")
}

build_tag_specifications() {
    local tags_json i
    tags_json="$(jq -n --arg purpose "$DEFAULT_PURPOSE" '[{Key:"Purpose",Value:$purpose}]')"
    if [[ ${#TAG_KEYS[@]} -gt 0 ]]; then
        for i in "${!TAG_KEYS[@]}"; do
            tags_json="$(jq -c --arg k "${TAG_KEYS[$i]}" --arg v "${TAG_VALUES[$i]}" \
                '. + [{Key:$k,Value:$v}]' <<< "$tags_json")"
        done
    fi
    jq -nc --argjson tags "$tags_json" \
        '[{ResourceType:"snapshot",Tags:$tags}]'
}

format_tags_preview() {
    local line="Purpose=${DEFAULT_PURPOSE}"
    local i
    if [[ ${#TAG_KEYS[@]} -gt 0 ]]; then
        for i in "${!TAG_KEYS[@]}"; do
            line+=", ${TAG_KEYS[$i]}=${TAG_VALUES[$i]}"
        done
    fi
    printf '%s' "$line"
}

confirm_action() {
    local prompt="$1"
    local reply
    if [[ "$SKIP_CONFIRM" = true ]]; then
        return 0
    fi
    warning "$prompt"
    read -r -p "Continue? [y/N] " reply
    reply="$(strip_cr "$reply")"
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)
            info "Skipped"
            return 1
            ;;
    esac
}

fetch_instance_and_volumes() {
    local instance_id="$1"
    local raw
    if ! raw=$(aws_json_quiet ec2 describe-instances --instance-ids "$instance_id"); then
        return 1
    fi
    printf '%s' "$raw" | jq -c --arg iid "$instance_id" '
      (.Reservations[0].Instances[0] // null) as $inst
      | if $inst == null then
          empty
        else
          {
            instanceId: $iid,
            state: ($inst.State.Name // "unknown"),
            instanceType: ($inst.InstanceType // null),
            volumes: (
              [$inst.BlockDeviceMappings[]?
                | select(.Ebs.VolumeId != null)
                | {
                    volumeId: .Ebs.VolumeId,
                    device: (.DeviceName // null),
                    deleteOnTermination: (.Ebs.DeleteOnTermination // null)
                  }
              ] | unique_by(.volumeId)
            )
          }
        end
    '
}

process_instance() {
    local instance_id="$1"
    local result_file="$2"
    local preview desc tag_spec created wait_ids snap_json utc status message
    local -a snapshot_ids=()

    utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    desc="Manual final snapshot for ${instance_id} at ${utc}"

    info "Processing $instance_id"
    if ! preview=$(fetch_instance_and_volumes "$instance_id"); then
        error "Instance not found or describe-instances failed: $instance_id"
        jq -n --arg iid "$instance_id" --arg msg "Instance not found or describe-instances failed" \
            '{instanceId:$iid,status:"failed",message:$msg,volumes:[],snapshots:[]}' > "$result_file"
        return 1
    fi
    if [[ -z "$preview" || "$preview" == "null" ]]; then
        error "Instance not returned by describe-instances: $instance_id"
        jq -n --arg iid "$instance_id" --arg msg "Instance not returned by describe-instances" \
            '{instanceId:$iid,status:"failed",message:$msg,volumes:[],snapshots:[]}' > "$result_file"
        return 1
    fi

    local state vol_count
    state="$(printf '%s' "$preview" | jq -r '.state')"
    vol_count="$(printf '%s' "$preview" | jq '.volumes | length')"

    info "  State: $state"
    info "  Attached volumes: $vol_count"
    printf '%s' "$preview" | jq -r '.volumes[] | "    - \(.volumeId) device=\(.device // "-") deleteOnTermination=\(.deleteOnTermination|tostring)"' >&2
    info "  Copy volume tags: yes"
    info "  Tags to add: $(format_tags_preview)"
    info "  Description: $desc"

    if [[ "$vol_count" -eq 0 ]]; then
        warning "  No attached EBS volumes; nothing to snapshot"
        jq -n --argjson preview "$preview" --arg msg "No attached EBS volumes" \
            '$preview + {status:"failed",message:$msg,snapshots:[]}' > "$result_file"
        return 1
    fi

    if [[ "$DRY_RUN" = true ]]; then
        success "  Dry-run: would create snapshots (no changes made)"
        jq -n --argjson preview "$preview" --arg desc "$desc" --arg tags "$(format_tags_preview)" \
            '$preview + {
              status:"dry-run",
              message:"Preview only; create-snapshots not called",
              description:$desc,
              tagsToAdd:$tags,
              copyTagsFromSource:"volume",
              snapshots:[]
            }' > "$result_file"
        return 0
    fi

    if ! confirm_action "Create snapshots for $instance_id ($vol_count volume(s))?"; then
        jq -n --argjson preview "$preview" \
            '$preview + {status:"skipped",message:"User declined confirmation",snapshots:[]}' > "$result_file"
        return 1
    fi

    tag_spec="$(build_tag_specifications)"
    info "  Calling create-snapshots..."
    if ! created=$(aws_json ec2 create-snapshots \
        --instance-specification "InstanceId=$instance_id" \
        --copy-tags-from-source volume \
        --description "$desc" \
        --tag-specifications "$tag_spec"); then
        jq -n --argjson preview "$preview" --arg msg "create-snapshots failed" \
            '$preview + {status:"failed",message:$msg,snapshots:[]}' > "$result_file"
        return 1
    fi

    snap_json="$(printf '%s' "$created" | jq -c '
      [.Snapshots[]? | {
        snapshotId: .SnapshotId,
        volumeId: (.VolumeId // null),
        state: (.State // null),
        description: (.Description // null)
      }]
    ')"
    mapfile -t snapshot_ids < <(printf '%s' "$snap_json" | jq -r '.[].snapshotId // empty' | sanitize_stream)

    success "  Created ${#snapshot_ids[@]} snapshot(s): ${snapshot_ids[*]:-}"

    if [[ "$WAIT_SNAPSHOTS" = true && ${#snapshot_ids[@]} -gt 0 ]]; then
        info "  Waiting for snapshot completion..."
        wait_ids="${snapshot_ids[*]}"
        # shellcheck disable=SC2086
        if aws_cmd ec2 wait snapshot-completed --snapshot-ids $wait_ids; then
            success "  Snapshots completed"
        else
            error "  Wait failed for one or more snapshots"
            jq -n --argjson preview "$preview" --argjson snaps "$snap_json" --arg msg "Snapshots created but wait failed" \
                '$preview + {status:"failed",message:$msg,snapshots:$snaps}' > "$result_file"
            return 1
        fi
    fi

    jq -n --argjson preview "$preview" --argjson snaps "$snap_json" --arg desc "$desc" \
        '$preview + {
          status:"success",
          message:"Snapshots created",
          description:$desc,
          copyTagsFromSource:"volume",
          snapshots:$snaps
        }' > "$result_file"
    return 0
}

write_summary() {
    local overall="success"
    local summary
    if [[ ${#RESULT_FILES[@]} -eq 0 ]]; then
        error "No results to write"
        return 1
    fi

    summary="$(jq -s \
        --arg accountId "$ACCOUNT_ID" \
        --arg region "$EFFECTIVE_REGION" \
        --arg profile "$PROFILE" \
        --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson dryRun "$DRY_RUN" \
        --arg purpose "$DEFAULT_PURPOSE" \
        '{
          accountId: $accountId,
          region: $region,
          profile: (if $profile == "" then null else $profile end),
          generatedAt: $generatedAt,
          options: {
            dryRun: $dryRun,
            defaultPurpose: $purpose,
            copyTagsFromSource: "volume"
          },
          instances: .
        }' "${RESULT_FILES[@]}")"

    if printf '%s' "$summary" | jq -e '
      any(.instances[]; .status == "failed" or .status == "skipped")
    ' >/dev/null; then
        overall="failed"
    fi

    mkdir -p "$REPORT_PATH"
    printf '%s\n' "$(printf '%s' "$summary" | jq '.')" > "$REPORT_PATH/summary.json"
    info "Wrote $REPORT_PATH/summary.json"

    if [[ "$overall" == "failed" ]]; then
        return 1
    fi
    return 0
}

print_banner() {
    echo "" >&2
    echo "╔════════════════════════════════════════════════════════╗" >&2
    echo "║          EC2 MANUAL / FINAL SNAPSHOTS                  ║" >&2
    echo "╚════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
}

main() {
    print_banner
    check_dependencies

    [[ -n "$PROFILE" ]] && PROFILE_ARG="--profile $PROFILE"
    [[ -n "$REGION" ]] && REGION_ARG="--region $REGION"

    check_aws_auth

    info "Instance IDs: ${INSTANCE_IDS[*]}"
    info "Tags to add: $(format_tags_preview)"
    if [[ "$DRY_RUN" = true ]]; then
        warning "DRY RUN: no snapshots will be created"
    fi

    if [[ -z "$REPORT_DIR" ]]; then
        REPORT_DIR="report/ec2-final-snapshot-$(date +%Y%m%d-%H%M%S)"
    fi
    REPORT_PATH="$REPORT_DIR"
    mkdir -p "$REPORT_PATH"

    local id result_file failures=0
    for id in "${INSTANCE_IDS[@]}"; do
        result_file="$(mktemp "$REPORT_PATH/instance-XXXXXX.json")"
        if ! process_instance "$id" "$result_file"; then
            failures=$((failures + 1))
        fi
        RESULT_FILES+=("$result_file")
    done

    if write_summary; then
        success "All instances processed successfully"
        info "Report: $REPORT_PATH"
        exit 0
    else
        error "Completed with failures or skips ($failures instance(s))"
        info "Report: $REPORT_PATH"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance|-i)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --instance requires a value"
                exit 1
            fi
            add_instance_ids "$2"
            shift 2
            ;;
        --region|-r)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --region requires a value"
                exit 1
            fi
            REGION="$(strip_cr "$2")"
            shift 2
            ;;
        --profile|-p)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --profile requires a value"
                exit 1
            fi
            PROFILE="$(strip_cr "$2")"
            shift 2
            ;;
        --tag)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --tag requires Key=Value"
                exit 1
            fi
            add_tag "$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --wait)
            WAIT_SNAPSHOTS=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --report-dir)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --report-dir requires a value"
                exit 1
            fi
            REPORT_DIR="$(strip_cr "$2")"
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

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    error "Missing required argument: --instance / -i"
    usage
    exit 1
fi

dedupe_instances
main "$@"
