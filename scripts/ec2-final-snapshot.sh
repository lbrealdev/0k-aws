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
MODE="volumes"
DRY_RUN=false
WAIT_SNAPSHOTS=false
SKIP_CONFIRM=false
NO_REBOOT=false
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

Create intentional final backups for live EC2 instances.

Modes:
  volumes (default)  aws ec2 create-snapshots — EBS snapshots of attached volumes
                     (copies volume tags + Purpose=${DEFAULT_PURPOSE})
  ami                aws ec2 create-image — AMI + backing snapshots (relaunchable)
                     (copies instance tags + Purpose + optional --tag onto AMI and snapshots)

Does NOT terminate or delete resources. Instance must exist.

Required arguments:
  --instance, -i     One or more instance IDs (repeatable or comma-separated)

Optional arguments:
  --mode             volumes (default) or ami
  --region, -r       AWS region
  --profile, -p      AWS profile name
  --tag Key=Value    Extra tag (repeatable; cannot override Purpose; overrides instance tags in AMI mode)
  --dry-run          Preview only; do not create snapshots or AMIs
  --wait             Wait until snapshots/AMI become available
  --no-reboot        AMI mode only: skip reboot (crash-consistent; less safe)
  --yes, -y          Skip confirmation prompt
  --report-dir       Report directory (default: report/ec2-final-snapshot-<timestamp>)
  --help, -h         Show this help message

Examples:
  $0 -i i-0123456789abcdef0 --region us-east-1 --dry-run
  $0 -i i-aaa --mode volumes --tag ChangeTicket=CHG123
  $0 -i i-aaa --mode ami --wait --yes
  $0 -i i-aaa --mode ami --no-reboot --dry-run

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

build_tags_json() {
    local tags_json i
    tags_json="$(jq -n --arg purpose "$DEFAULT_PURPOSE" '[{Key:"Purpose",Value:$purpose}]')"
    if [[ ${#TAG_KEYS[@]} -gt 0 ]]; then
        for i in "${!TAG_KEYS[@]}"; do
            tags_json="$(jq -c --arg k "${TAG_KEYS[$i]}" --arg v "${TAG_VALUES[$i]}" \
                '. + [{Key:$k,Value:$v}]' <<< "$tags_json")"
        done
    fi
    printf '%s' "$tags_json"
}

# Merge instance tags + --tag + Purpose for AMI mode.
# Precedence: Purpose > --tag > instance tags. Skips aws:* keys. Max 50 tags.
build_ami_tags_json() {
    local instance_tags_json="${1:-[]}"
    local overlay_json='[]'
    local tags_json count i

    if [[ ${#TAG_KEYS[@]} -gt 0 ]]; then
        for i in "${!TAG_KEYS[@]}"; do
            overlay_json="$(jq -c --arg k "${TAG_KEYS[$i]}" --arg v "${TAG_VALUES[$i]}" \
                '. + [{Key:$k,Value:$v}]' <<< "$overlay_json")"
        done
    fi

    tags_json="$(jq -nc \
        --argjson instance "$instance_tags_json" \
        --argjson overlay "$overlay_json" \
        --arg purpose "$DEFAULT_PURPOSE" '
          (
            ($instance // [])
            | map(select(
                (.Key | type == "string") and (.Key | length > 0) and
                (.Value | type == "string") and
                (.Key | startswith("aws:") | not)
              ))
            | map({(.Key): .Value})
            | add // {}
          ) as $base
          | (
              ($overlay // [])
              | map({(.Key): .Value})
              | add // {}
            ) as $over
          | ($base + $over + {Purpose: $purpose})
          | to_entries
          | map({Key: .key, Value: .value})
          | sort_by(.Key)
        ')"

    count="$(printf '%s' "$tags_json" | jq 'length')"
    if [[ "$count" -gt 50 ]]; then
        error "Merged AMI tags exceed AWS limit of 50 (got ${count})"
        return 1
    fi
    printf '%s' "$tags_json"
}

build_tag_specifications_volumes() {
    jq -nc --argjson tags "$(build_tags_json)" \
        '[{ResourceType:"snapshot",Tags:$tags}]'
}

build_tag_specifications_ami() {
    # Same tags on AMI and all backing snapshots (AWS applies one snapshot tag set to every volume).
    local tags_json="$1"
    jq -nc --argjson tags "$tags_json" \
        '[
          {ResourceType:"image",Tags:$tags},
          {ResourceType:"snapshot",Tags:$tags}
        ]'
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

format_tags_json_preview() {
    local tags_json="$1"
    jq -r 'map("\(.Key)=\(.Value)") | join(", ")' <<< "$tags_json"
}

sanitize_ami_name_component() {
    # AMI names allow: letters, digits, spaces, and ()./_-
    # We normalize whitespace to '-' and drop unsupported characters.
    local raw="$1"
    local cleaned
    cleaned="$(printf '%s' "$raw" | tr -d '\r')"
    cleaned="$(printf '%s' "$cleaned" | sed -E \
        -e 's/[[:space:]]+/-/g' \
        -e 's/[^A-Za-z0-9()._/-]/-/g' \
        -e 's/-+/-/g' \
        -e 's/^-+//' \
        -e 's/-+$//')"
    printf '%s' "$cleaned"
}

ami_name_for_instance() {
    local name_tag="${1:-}"
    local stamp sanitized_name fixed_suffix fixed_len max_name_len name_part
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    fixed_suffix="-${stamp}-final"
    fixed_len="${#fixed_suffix}"

    # AWS AMI name max length is 128. Keep stamp and -final intact.
    # Instance ID is omitted from the name (still present in description / report).
    if [[ "$fixed_len" -ge 128 ]]; then
        printf '%s' "${stamp}-final" | cut -c1-128
        return 0
    fi

    sanitized_name="$(sanitize_ami_name_component "$name_tag")"
    if [[ -z "$sanitized_name" ]]; then
        printf '%s' "${stamp}-final"
        return 0
    fi

    max_name_len=$((128 - fixed_len))
    if [[ "$max_name_len" -lt 1 ]]; then
        printf '%s' "${stamp}-final" | cut -c1-128
        return 0
    fi
    name_part="$(printf '%s' "$sanitized_name" | cut -c1-"$max_name_len")"
    name_part="$(printf '%s' "$name_part" | sed -E 's/-+$//')"
    if [[ -z "$name_part" ]]; then
        printf '%s' "${stamp}-final"
        return 0
    fi
    printf '%s%s' "$name_part" "$fixed_suffix"
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
            nameTag: (
              (($inst.Tags // []) | map(select(.Key == "Name")) | .[0].Value) // null
            ),
            tags: (
              [($inst.Tags // [])[] | {Key: .Key, Value: .Value}]
            ),
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

fetch_ami_backing_snapshots() {
    local image_id="$1"
    local raw
    if ! raw=$(aws_json_quiet ec2 describe-images --image-ids "$image_id"); then
        echo '[]'
        return 0
    fi
    printf '%s' "$raw" | jq -c '
      [.Images[0].BlockDeviceMappings[]?
        | select(.Ebs.SnapshotId != null)
        | {
            snapshotId: .Ebs.SnapshotId,
            device: (.DeviceName // null),
            volumeSize: (.Ebs.VolumeSize // null)
          }
      ]
    '
}

write_failed_result() {
    local result_file="$1"
    local instance_id="$2"
    local msg="$3"
    jq -n --arg iid "$instance_id" --arg msg "$msg" --arg mode "$MODE" \
        '{instanceId:$iid,mode:$mode,status:"failed",message:$msg,volumes:[],snapshots:[],ami:null}' \
        > "$result_file"
}

process_instance_volumes() {
    local instance_id="$1"
    local preview="$2"
    local result_file="$3"
    local desc tag_spec created snap_json wait_ids utc state vol_count
    local -a snapshot_ids=()

    utc="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    desc="Manual final snapshot for ${instance_id} at ${utc}"
    state="$(printf '%s' "$preview" | jq -r '.state')"
    vol_count="$(printf '%s' "$preview" | jq '.volumes | length')"

    info "  Mode: volumes"
    info "  State: $state"
    info "  Attached volumes: $vol_count"
    printf '%s' "$preview" | jq -r '.volumes[] | "    - \(.volumeId) device=\(.device // "-") deleteOnTermination=\(.deleteOnTermination|tostring)"' >&2
    info "  Copy volume tags: yes"
    info "  Tags to add: $(format_tags_preview)"
    info "  Description: $desc"

    if [[ "$vol_count" -eq 0 ]]; then
        warning "  No attached EBS volumes; nothing to snapshot"
        jq -n --argjson preview "$preview" --arg msg "No attached EBS volumes" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
        return 1
    fi

    if [[ "$DRY_RUN" = true ]]; then
        success "  Dry-run: would create volume snapshots (no changes made)"
        jq -n --argjson preview "$preview" --arg desc "$desc" --arg tags "$(format_tags_preview)" --arg mode "$MODE" \
            '$preview + {
              mode:$mode,
              status:"dry-run",
              message:"Preview only; create-snapshots not called",
              description:$desc,
              tagsToAdd:$tags,
              copyTagsFromSource:"volume",
              snapshots:[],
              ami:null
            }' > "$result_file"
        return 0
    fi

    if ! confirm_action "Create volume snapshots for $instance_id ($vol_count volume(s))?"; then
        jq -n --argjson preview "$preview" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"skipped",message:"User declined confirmation",snapshots:[],ami:null}' \
            > "$result_file"
        return 1
    fi

    tag_spec="$(build_tag_specifications_volumes)"
    info "  Calling create-snapshots..."
    if ! created=$(aws_json ec2 create-snapshots \
        --instance-specification "InstanceId=$instance_id" \
        --copy-tags-from-source volume \
        --description "$desc" \
        --tag-specifications "$tag_spec"); then
        jq -n --argjson preview "$preview" --arg msg "create-snapshots failed" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
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
            jq -n --argjson preview "$preview" --argjson snaps "$snap_json" --arg msg "Snapshots created but wait failed" --arg mode "$MODE" \
                '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:$snaps,ami:null}' > "$result_file"
            return 1
        fi
    fi

    jq -n --argjson preview "$preview" --argjson snaps "$snap_json" --arg desc "$desc" --arg mode "$MODE" \
        '$preview + {
          mode:$mode,
          status:"success",
          message:"Snapshots created",
          description:$desc,
          copyTagsFromSource:"volume",
          snapshots:$snaps,
          ami:null
        }' > "$result_file"
    return 0
}

process_instance_ami() {
    local instance_id="$1"
    local preview="$2"
    local result_file="$3"
    local desc ami_name tag_spec created image_id snap_json utc state vol_count reboot_note name_tag
    local instance_tags_json ami_tags_json tags_preview
    local create_args=()

    utc="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    desc="Manual final AMI for ${instance_id} at ${utc}"
    name_tag="$(printf '%s' "$preview" | jq -r '.nameTag // empty' | tr -d '\r')"
    ami_name="$(ami_name_for_instance "$name_tag")"
    state="$(printf '%s' "$preview" | jq -r '.state')"
    vol_count="$(printf '%s' "$preview" | jq '.volumes | length')"
    instance_tags_json="$(printf '%s' "$preview" | jq -c '.tags // []')"

    if ! ami_tags_json="$(build_ami_tags_json "$instance_tags_json")"; then
        jq -n --argjson preview "$preview" --arg msg "Merged AMI tags exceed AWS limit of 50" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
        return 1
    fi
    tags_preview="$(format_tags_json_preview "$ami_tags_json")"

    if [[ "$NO_REBOOT" = true ]]; then
        reboot_note="no-reboot (crash-consistent; filesystem integrity not guaranteed)"
    elif [[ "$state" == "running" ]]; then
        reboot_note="AWS default reboot (running instance will reboot during AMI creation)"
    else
        reboot_note="instance is ${state}; AWS will not start a stopped instance for AMI creation"
    fi

    info "  Mode: ami"
    info "  State: $state"
    info "  Name tag: ${name_tag:-<none>}"
    info "  Attached volumes: $vol_count"
    printf '%s' "$preview" | jq -r '.volumes[] | "    - \(.volumeId) device=\(.device // "-") deleteOnTermination=\(.deleteOnTermination|tostring)"' >&2
    info "  AMI name (generated): $ami_name"
    info "  Reboot behavior: $reboot_note"
    info "  Copy instance tags: yes (aws:* skipped; Purpose/--tag win on conflicts)"
    info "  Tags to add: $tags_preview"
    info "  Description: $desc"

    if [[ "$vol_count" -eq 0 ]]; then
        warning "  No attached EBS volumes; cannot create EBS-backed AMI"
        jq -n --argjson preview "$preview" --arg msg "No attached EBS volumes" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
        return 1
    fi

    if [[ "$DRY_RUN" = true ]]; then
        success "  Dry-run: would create AMI (no changes made)"
        jq -n \
            --argjson preview "$preview" \
            --arg desc "$desc" \
            --arg tags "$tags_preview" \
            --argjson amiTags "$ami_tags_json" \
            --arg mode "$MODE" \
            --arg amiName "$ami_name" \
            --arg reboot "$reboot_note" \
            --argjson noReboot "$NO_REBOOT" \
            '$preview + {
              mode:$mode,
              status:"dry-run",
              message:"Preview only; create-image not called",
              description:$desc,
              tagsToAdd:$tags,
              amiTags:$amiTags,
              copyTagsFromSource:"instance",
              rebootBehavior:$reboot,
              noReboot:$noReboot,
              snapshots:[],
              ami:{imageId:null,name:$amiName,state:null}
            }' > "$result_file"
        return 0
    fi

    if ! confirm_action "Create AMI for $instance_id ($vol_count volume(s))? $reboot_note"; then
        jq -n --argjson preview "$preview" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"skipped",message:"User declined confirmation",snapshots:[],ami:null}' \
            > "$result_file"
        return 1
    fi

    tag_spec="$(build_tag_specifications_ami "$ami_tags_json")"
    create_args=(
        ec2 create-image
        --instance-id "$instance_id"
        --name "$ami_name"
        --description "$desc"
        --tag-specifications "$tag_spec"
    )
    if [[ "$NO_REBOOT" = true ]]; then
        create_args+=(--no-reboot)
    fi

    info "  Calling create-image..."
    if ! created=$(aws_json "${create_args[@]}"); then
        jq -n --argjson preview "$preview" --arg msg "create-image failed" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
        return 1
    fi

    image_id="$(printf '%s' "$created" | jq -r '.ImageId // empty' | tr -d '\r')"
    if [[ -z "$image_id" ]]; then
        error "  create-image returned no ImageId"
        jq -n --argjson preview "$preview" --arg msg "create-image returned no ImageId" --arg mode "$MODE" \
            '$preview + {mode:$mode,status:"failed",message:$msg,snapshots:[],ami:null}' > "$result_file"
        return 1
    fi
    success "  Created AMI: $image_id ($ami_name)"

    if [[ "$WAIT_SNAPSHOTS" = true ]]; then
        info "  Waiting for AMI to become available..."
        if aws_cmd ec2 wait image-available --image-ids "$image_id"; then
            success "  AMI available"
        else
            error "  Wait failed for AMI $image_id"
            snap_json="$(fetch_ami_backing_snapshots "$image_id")"
            jq -n \
                --argjson preview "$preview" \
                --argjson snaps "$snap_json" \
                --argjson amiTags "$ami_tags_json" \
                --arg tags "$tags_preview" \
                --arg imageId "$image_id" \
                --arg amiName "$ami_name" \
                --arg msg "AMI created but wait failed" \
                --arg mode "$MODE" \
                --arg reboot "$reboot_note" \
                --argjson noReboot "$NO_REBOOT" \
                '$preview + {
                  mode:$mode,
                  status:"failed",
                  message:$msg,
                  tagsToAdd:$tags,
                  amiTags:$amiTags,
                  copyTagsFromSource:"instance",
                  rebootBehavior:$reboot,
                  noReboot:$noReboot,
                  snapshots:$snaps,
                  ami:{imageId:$imageId,name:$amiName,state:"pending"}
                }' > "$result_file"
            return 1
        fi
    fi

    snap_json="$(fetch_ami_backing_snapshots "$image_id")"
    jq -n \
        --argjson preview "$preview" \
        --argjson snaps "$snap_json" \
        --argjson amiTags "$ami_tags_json" \
        --arg tags "$tags_preview" \
        --arg desc "$desc" \
        --arg imageId "$image_id" \
        --arg amiName "$ami_name" \
        --arg mode "$MODE" \
        --arg reboot "$reboot_note" \
        --argjson noReboot "$NO_REBOOT" \
        '$preview + {
          mode:$mode,
          status:"success",
          message:"AMI created",
          description:$desc,
          tagsToAdd:$tags,
          amiTags:$amiTags,
          copyTagsFromSource:"instance",
          rebootBehavior:$reboot,
          noReboot:$noReboot,
          snapshots:$snaps,
          ami:{imageId:$imageId,name:$amiName,state:null}
        }' > "$result_file"
    return 0
}

process_instance() {
    local instance_id="$1"
    local result_file="$2"
    local preview

    info "Processing $instance_id"
    if ! preview=$(fetch_instance_and_volumes "$instance_id"); then
        error "Instance not found or describe-instances failed: $instance_id"
        write_failed_result "$result_file" "$instance_id" "Instance not found or describe-instances failed"
        return 1
    fi
    if [[ -z "$preview" || "$preview" == "null" ]]; then
        error "Instance not returned by describe-instances: $instance_id"
        write_failed_result "$result_file" "$instance_id" "Instance not returned by describe-instances"
        return 1
    fi

    case "$MODE" in
        volumes) process_instance_volumes "$instance_id" "$preview" "$result_file" ;;
        ami) process_instance_ami "$instance_id" "$preview" "$result_file" ;;
        *)
            error "Invalid mode: $MODE"
            write_failed_result "$result_file" "$instance_id" "Invalid mode"
            return 1
            ;;
    esac
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
        --arg generatedAt "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
        --argjson dryRun "$DRY_RUN" \
        --arg purpose "$DEFAULT_PURPOSE" \
        --arg mode "$MODE" \
        --argjson noReboot "$NO_REBOOT" \
        '{
          accountId: $accountId,
          region: $region,
          profile: (if $profile == "" then null else $profile end),
          generatedAt: $generatedAt,
          options: {
            mode: $mode,
            dryRun: $dryRun,
            defaultPurpose: $purpose,
            noReboot: $noReboot,
            copyTagsFromSource: (if $mode == "volumes" then "volume" elif $mode == "ami" then "instance" else null end)
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

    info "Mode: $MODE"
    info "Instance IDs: ${INSTANCE_IDS[*]}"
    info "Tags to add: $(format_tags_preview)"
    if [[ "$MODE" == "ami" ]]; then
        if [[ "$NO_REBOOT" = true ]]; then
            warning "AMI mode: --no-reboot set (crash-consistent)"
        else
            info "AMI mode: running instances will reboot by default during create-image"
        fi
    elif [[ "$NO_REBOOT" = true ]]; then
        warning "--no-reboot is ignored in volumes mode"
    fi
    if [[ "$DRY_RUN" = true ]]; then
        warning "DRY RUN: no snapshots or AMIs will be created"
    fi

    if [[ -z "$REPORT_DIR" ]]; then
        REPORT_DIR="report/ec2-final-snapshot-$(date -u +%Y%m%d-%H%M%S)"
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
        --mode)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --mode requires a value (volumes|ami)"
                exit 1
            fi
            MODE="$(strip_cr "$2" | tr '[:upper:]' '[:lower:]')"
            case "$MODE" in
                volumes|ami) ;;
                *)
                    error "Invalid mode: $MODE (expected volumes or ami)"
                    exit 1
                    ;;
            esac
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
        --no-reboot)
            NO_REBOOT=true
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
