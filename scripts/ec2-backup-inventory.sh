#!/usr/bin/env bash

set -euo pipefail

# Platform note: Git Bash / MSYS may emit CRLF from external commands.
# Always sanitize captured values with strip_cr before compare/parse/store.
strip_cr() {
    printf '%s' "$1" | tr -d '\r'
}

sanitize_stream() {
    tr -d '\r'
}

detect_platform() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null | tr -d '\r')"
    if [[ -n "${MSYSTEM:-}" || "$uname_s" == MINGW* || "$uname_s" == MSYS* || "$uname_s" == CYGWIN* ]]; then
        PLATFORM="git-bash"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        PLATFORM="wsl"
    else
        PLATFORM="linux"
    fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

timestamp() {
    date '+%H:%M:%S'
}

now_epoch() {
    date +%s
}

elapsed_since() {
    local start="$1"
    echo "$(($(now_epoch) - start))"
}

info() {
    # stderr so command substitutions / json|csv stdout stay clean
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

usage() {
    cat << EOF
Usage: $0 --instance <instance-id>[,<instance-id>...] [OPTIONS]

Read-only, instance-scoped inventory for EC2 elimination:
  volumes (including leftovers), snapshots, AMIs, DLM policies, and AWS Backup recovery points.
  Correlates related resources by instance/volume IDs and tags.

Required arguments:
  --instance, -i     One or more instance IDs (repeatable or comma-separated)

Optional arguments:
  --region, -r       AWS region
  --profile, -p      AWS profile name
  --format, -f       Output format: table, json, or csv (default: table)
  --report           Write summary.json and CSV files under a report directory
  --report-dir       Custom report directory (implies --report)
  --skip-backup      Skip AWS Backup vault/recovery-point enumeration
  --skip-dlm         Skip Data Lifecycle Manager policies
  --help, -h         Show this help message

Examples:
  $0 -i i-0123456789abcdef0 --region us-east-1
  $0 -i i-aaa,i-bbb --profile prod --format json
  $0 -i i-aaa -i i-bbb --format csv --report
  $0 -i i-aaa --skip-dlm --report-dir ./out/ec2-elim

EOF
}

PROFILE=""
REGION=""
FORMAT="table"
REPORT=false
REPORT_DIR=""
SKIP_BACKUP=false
SKIP_DLM=false
ACCOUNT_ID=""
EFFECTIVE_REGION=""
PLATFORM=""
PROFILE_ARG=""
REGION_ARG=""
REPORT_PATH=""
INSTANCE_IDS=()

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
        --format|-f)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                error "Option --format requires a value"
                exit 1
            fi
            FORMAT="$(strip_cr "$2" | tr '[:upper:]' '[:lower:]')"
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
            REPORT_DIR="$(strip_cr "$2")"
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

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    error "Missing required argument: --instance / -i"
    usage
    exit 1
fi

# Deduplicate instance IDs while preserving order
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
dedupe_instances

case "$FORMAT" in
    table|json|csv) ;;
    *)
        error "Invalid format: $FORMAT (expected table, json, or csv)"
        exit 1
        ;;
esac

fetch_instance_json() {
    local instance_id="$1"
    local raw start
    start="$(now_epoch)"
    info "  1/5 Describe instance..."
    if ! raw=$(aws_json_quiet ec2 describe-instances --instance-ids "$instance_id"); then
        # describe-instances fails for unknown/purged IDs
        info "  Instance not returned by describe-instances ($(elapsed_since "$start")s)"
        echo "null"
        return 0
    fi
    local instance
    instance="$(printf '%s' "$raw" | jq -c '.Reservations[0].Instances[0] // null')"
    if [[ "$instance" == "null" ]]; then
        info "  Instance not found in response ($(elapsed_since "$start")s)"
    else
        local state
        state="$(printf '%s' "$instance" | jq -r '.State.Name // "unknown"')"
        info "  Instance found: $state ($(elapsed_since "$start")s)"
    fi
    printf '%s' "$instance"
}

collect_volumes_for_instance() {
    local instance_id="$1"
    local instance_json="$2"
    local volume_ids_json volumes_by_id tagged_volumes attached_volumes start result

    start="$(now_epoch)"
    info "  2/5 Discover volumes..."
    volume_ids_json="$(printf '%s' "$instance_json" | jq -c '
      [.BlockDeviceMappings[]?.Ebs?.VolumeId // empty]
      | unique
    ')"
    info "    BDM volume IDs: $(printf '%s' "$volume_ids_json" | jq -r 'if length == 0 then "(none)" else join(",") end')"

    # Volumes currently attached (or still showing attachment) to this instance
    info "    Querying volumes by attachment filter..."
    attached_volumes="$(aws_json_quiet ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$instance_id" \
        | jq -c '.Volumes // []' || echo '[]')"
    info "    Attachment-filter volumes: $(printf '%s' "$attached_volumes" | jq 'length')"

    # Tag discovery: volumes whose tag values mention the instance id
    info "    Querying volumes by tag match..."
    tagged_volumes="$(aws_json_quiet ec2 describe-volumes \
        | jq -c --arg iid "$instance_id" '
          [.Volumes[]?
            | select(
                ((.Tags // []) | map(.Value) | join(" ") | contains($iid))
                or ((.Tags // []) | map("\(.Key)=\(.Value)") | join(" ") | contains($iid))
              )
          ]
        ' || echo '[]')"
    info "    Tag-matched volumes: $(printf '%s' "$tagged_volumes" | jq 'length')"

    volumes_by_id='[]'
    if [[ "$volume_ids_json" != "[]" ]]; then
        local ids
        ids="$(printf '%s' "$volume_ids_json" | jq -r '.[]' | tr '\n' ' ' | tr -d '\r')"
        if [[ -n "${ids//[[:space:]]/}" ]]; then
            # Intentionally unquoted expansion of volume ids for AWS CLI
            # shellcheck disable=SC2086
            info "    Querying volumes by BDM IDs..."
            volumes_by_id="$(aws_json_quiet ec2 describe-volumes --volume-ids $ids \
                | jq -c '.Volumes // []' || echo '[]')"
            info "    BDM-described volumes: $(printf '%s' "$volumes_by_id" | jq 'length')"
        fi
    fi

    result="$(jq -n \
        --arg iid "$instance_id" \
        --argjson from_bdm "$volumes_by_id" \
        --argjson attached "$attached_volumes" \
        --argjson tagged "$tagged_volumes" \
        '
        def norm:
          map({
            volumeId: .VolumeId,
            size: .Size,
            volumeType: .VolumeType,
            state: .State,
            availabilityZone: .AvailabilityZone,
            createTime: .CreateTime,
            encrypted: .Encrypted,
            attachedInstanceId: (.Attachments[0].InstanceId // null),
            device: (.Attachments[0].Device // null),
            deleteOnTermination: (.Attachments[0].DeleteOnTermination // null),
            leftover: ((.State == "available") or ((.Attachments // []) | length == 0)),
            tags: (if .Tags == null then {} else reduce .Tags[] as $t ({}; . + {($t.Key): $t.Value}) end),
            matchReason: []
          });

        (($from_bdm | norm | map(.matchReason += ["block-device-mapping"]))
         + ($attached | norm | map(.matchReason += ["attachment.instance-id"]))
         + ($tagged | norm | map(.matchReason += ["tag-contains-instance-id"])))
        | group_by(.volumeId)
        | map(.[0] + {
            matchReason: (map(.matchReason[]) | unique)
          })
        | map(. + {instanceId: $iid})
        '
    )"
    info "  Volumes found: $(printf '%s' "$result" | jq 'length') ($(elapsed_since "$start")s)"
    printf '%s' "$result"
}

collect_snapshots_for_instance() {
    local instance_id="$1"
    local volumes_json="$2"
    local volume_ids snaps start result

    start="$(now_epoch)"
    info "  3/5 Discover snapshots..."
    volume_ids="$(printf '%s' "$volumes_json" | jq -c '[.[].volumeId]')"
    info "    Known volume IDs: $(printf '%s' "$volume_ids" | jq -r 'if length == 0 then "(none)" else join(",") end')"

    info "    Querying account-owned snapshots..."
    snaps="$(aws_json_quiet ec2 describe-snapshots --owner-ids "$ACCOUNT_ID" || echo '{"Snapshots":[]}')"
    info "    Account-owned snapshots scanned: $(printf '%s' "$snaps" | jq '.Snapshots | length')"

    result="$(printf '%s' "$snaps" | jq -c --arg iid "$instance_id" --argjson vids "$volume_ids" '
      def tag_obj:
        if . == null then {} else reduce .[] as $t ({}; . + {($t.Key): $t.Value}) end;

      [.Snapshots[]?
        | . as $s
        | ($s.Tags | tag_obj) as $tags
        | ($tags | to_entries | map("\(.key)=\(.value)") | join(" ")) as $tag_text
        | select(
            (($vids | length > 0) and ($vids | index($s.VolumeId) != null))
            or (($s.Description // "") | contains($iid))
            or ($tag_text | contains($iid))
            or (
              ($vids | length > 0)
              and (
                any($vids[]; . as $vid
                  | (($s.Description // "") | contains($vid))
                    or ($tag_text | contains($vid))
                )
              )
            )
          )
        | {
            snapshotId: .SnapshotId,
            volumeId: .VolumeId,
            state: .State,
            startTime: .StartTime,
            volumeSize: .VolumeSize,
            description: (.Description // null),
            progress: (.Progress // null),
            tags: $tags,
            instanceId: $iid,
            matchReason: (
              [
                (if ($vids | index($s.VolumeId) != null) then "volume-id" else empty end),
                (if (($s.Description // "") | contains($iid)) then "description-instance-id" else empty end),
                (if ($tag_text | contains($iid)) then "tag-instance-id" else empty end),
                (if any($vids[]; . as $vid | (($s.Description // "") | contains($vid)) or ($tag_text | contains($vid))) then "description-or-tag-volume-id" else empty end)
              ] | unique
            )
          }
      ]
    ')"
    info "  Snapshots found: $(printf '%s' "$result" | jq 'length') ($(elapsed_since "$start")s)"
    printf '%s' "$result"
}

collect_amis_for_instance() {
    local instance_id="$1"
    local snapshots_json="$2"
    local snapshot_ids images start result

    start="$(now_epoch)"
    info "  4/5 Discover AMIs..."
    snapshot_ids="$(printf '%s' "$snapshots_json" | jq -c '[.[].snapshotId]')"
    info "    Known snapshot IDs: $(printf '%s' "$snapshot_ids" | jq -r 'if length == 0 then "(none)" else join(",") end')"
    info "    Querying owned AMIs..."
    images="$(aws_json_quiet ec2 describe-images --owners "$ACCOUNT_ID" || echo '{"Images":[]}')"
    info "    Owned AMIs scanned: $(printf '%s' "$images" | jq '.Images | length')"

    result="$(printf '%s' "$images" | jq -c --arg iid "$instance_id" --argjson sids "$snapshot_ids" '
      def tag_obj:
        if . == null then {} else reduce .[] as $t ({}; . + {($t.Key): $t.Value}) end;

      [.Images[]?
        | . as $img
        | ($img.Tags | tag_obj) as $tags
        | ($tags | to_entries | map("\(.key)=\(.value)") | join(" ")) as $tag_text
        | ([.BlockDeviceMappings[]?.Ebs?.SnapshotId // empty] | unique) as $ami_snaps
        | select(
            (($ami_snaps | length > 0) and any($ami_snaps[]; . as $sid | ($sids | index($sid) != null)))
            or (($img.Name // "") | contains($iid))
            or ($tag_text | contains($iid))
            or (($img.Description // "") | contains($iid))
          )
        | {
            imageId: .ImageId,
            name: (.Name // null),
            state: .State,
            creationDate: .CreationDate,
            rootDeviceType: .RootDeviceType,
            description: (.Description // null),
            snapshotIds: $ami_snaps,
            tags: $tags,
            instanceId: $iid,
            matchReason: (
              [
                (if any($ami_snaps[]; . as $sid | ($sids | index($sid) != null)) then "backing-snapshot" else empty end),
                (if (($img.Name // "") | contains($iid)) then "name-instance-id" else empty end),
                (if ($tag_text | contains($iid)) then "tag-instance-id" else empty end),
                (if (($img.Description // "") | contains($iid)) then "description-instance-id" else empty end)
              ] | unique
            )
          }
      ]
    ')"
    info "  AMIs found: $(printf '%s' "$result" | jq 'length') ($(elapsed_since "$start")s)"
    printf '%s' "$result"
}

query_backup_recovery_points_by_arn() {
    local resource_arn="$1"
    local instance_id="$2"
    local points normalized

    if ! points=$(aws_json_quiet backup list-recovery-points-by-resource \
        --resource-arn "$resource_arn"); then
        return 1
    fi

    normalized="$(printf '%s' "$points" | jq -c --arg iid "$instance_id" '
      [.RecoveryPoints[]? | {
        vaultName: (.BackupVaultName // null),
        recoveryPointArn: .RecoveryPointArn,
        resourceArn: (.ResourceArn // null),
        resourceType: (.ResourceType // null),
        creationDate: (.CreationDate // null),
        completionDate: (.CompletionDate // null),
        status: (.Status // null),
        instanceId: $iid,
        tags: {}
      }]
    ')"
    printf '%s' "$normalized"
}

collect_backup_for_instance() {
    local instance_id="$1"
    local volumes_json="$2"

    if [[ "$SKIP_BACKUP" = true ]]; then
        info "  5/5 Discover AWS Backup recovery points... skipped (--skip-backup)"
        echo '[]'
        return 0
    fi

    local start combined volume_ids volume_id instance_arn volume_arn points count
    start="$(now_epoch)"
    info "  5/5 Discover AWS Backup recovery points..."
    combined='[]'

    if [[ -z "$EFFECTIVE_REGION" || "$EFFECTIVE_REGION" == "not set" ]]; then
        warning "AWS region is not set; cannot build resource ARNs for Backup discovery"
        info "  Backup recovery points found: 0 ($(elapsed_since "$start")s)"
        echo '[]'
        return 0
    fi

    instance_arn="arn:aws:ec2:${EFFECTIVE_REGION}:${ACCOUNT_ID}:instance/${instance_id}"
    info "    Querying instance ARN..."
    if points=$(query_backup_recovery_points_by_arn "$instance_arn" "$instance_id"); then
        count="$(printf '%s' "$points" | jq 'length')"
        info "    Instance recovery points: $count"
        combined="$(jq -n --argjson acc "$combined" --argjson page "$points" '$acc + $page')"
    else
        warning "Could not list Backup recovery points for instance $instance_id"
    fi

    volume_ids="$(printf '%s' "$volumes_json" | jq -r '.[].volumeId // empty' | sanitize_stream)"
    while IFS= read -r volume_id; do
        volume_id="$(strip_cr "$volume_id")"
        [[ -z "$volume_id" ]] && continue
        volume_arn="arn:aws:ec2:${EFFECTIVE_REGION}:${ACCOUNT_ID}:volume/${volume_id}"
        info "    Querying volume $volume_id..."
        if points=$(query_backup_recovery_points_by_arn "$volume_arn" "$instance_id"); then
            count="$(printf '%s' "$points" | jq 'length')"
            info "    Volume $volume_id recovery points: $count"
            combined="$(jq -n --argjson acc "$combined" --argjson page "$points" '$acc + $page')"
        else
            warning "Could not list Backup recovery points for volume $volume_id"
        fi
    done <<< "$volume_ids"

    combined="$(printf '%s' "$combined" | jq -c '
      group_by(.recoveryPointArn)
      | map(.[0])
    ')"

    info "  Backup recovery points found: $(printf '%s' "$combined" | jq 'length') ($(elapsed_since "$start")s)"
    printf '%s' "$combined"
}

collect_dlm_policies() {
    if [[ "$SKIP_DLM" = true ]]; then
        info "DLM policies: skipped (--skip-dlm)"
        echo '[]'
        return 0
    fi

    local policies result start
    start="$(now_epoch)"
    info "Collecting DLM lifecycle policies..."
    if ! policies=$(aws_json_quiet dlm get-lifecycle-policies); then
        warning "Could not list DLM policies (permissions or service unavailable)"
        echo '[]'
        return 0
    fi

    result="$(printf '%s' "$policies" | jq -c '
      [.Policies[]? | {
        policyId: .PolicyId,
        description: (.Description // null),
        state: .State,
        policyType: (.PolicyType // null),
        defaultPolicy: (.DefaultPolicy // null)
      }]
    ')"
    info "DLM policies found: $(printf '%s' "$result" | jq 'length') ($(elapsed_since "$start")s)"
    printf '%s' "$result"
}

build_instance_record() {
    local instance_id="$1"
    local instance_json volumes snapshots amis backups notes found_json start

    start="$(now_epoch)"
    info "Collecting resources for $instance_id"
    instance_json="$(fetch_instance_json "$instance_id")"
    notes='[]'
    found_json='true'

    if [[ "$instance_json" == "null" ]]; then
        found_json='false'
        instance_json="$(jq -n --arg id "$instance_id" '{InstanceId:$id,Tags:[],BlockDeviceMappings:[]}')"
        notes='["Instance not returned by describe-instances; correlating by tags/ARNs only"]'
    fi

    volumes="$(collect_volumes_for_instance "$instance_id" "$instance_json")"
    snapshots="$(collect_snapshots_for_instance "$instance_id" "$volumes")"
    amis="$(collect_amis_for_instance "$instance_id" "$snapshots")"
    backups="$(collect_backup_for_instance "$instance_id" "$volumes")"
    info "Finished collecting resources for $instance_id ($(elapsed_since "$start")s)"

    jq -n \
        --argjson inst "$instance_json" \
        --argjson volumes "$volumes" \
        --argjson snapshots "$snapshots" \
        --argjson amis "$amis" \
        --argjson backups "$backups" \
        --argjson notes "$notes" \
        --argjson found "$found_json" \
        --arg iid "$instance_id" '
        def tag_obj:
          if . == null then {} else reduce .[] as $t ({}; . + {($t.Key): $t.Value}) end;

        {
          instanceId: $iid,
          found: $found,
          state: ($inst.State.Name // null),
          instanceType: ($inst.InstanceType // null),
          availabilityZone: ($inst.Placement.AvailabilityZone // null),
          launchTime: ($inst.LaunchTime // null),
          tags: ($inst.Tags | tag_obj),
          volumes: $volumes,
          snapshots: $snapshots,
          amis: $amis,
          backupRecoveryPoints: $backups,
          notes: $notes
        }
      '
}

build_summary() {
    local dlm records='[]' id record

    for id in "${INSTANCE_IDS[@]}"; do
        record="$(build_instance_record "$id")"
        records="$(jq -n --argjson acc "$records" --argjson rec "$record" '$acc + [$rec]')"
    done

    dlm="$(collect_dlm_policies)"

    jq -n \
        --arg accountId "$ACCOUNT_ID" \
        --arg region "$EFFECTIVE_REGION" \
        --arg profile "$PROFILE" \
        --arg platform "$PLATFORM" \
        --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson instances "$records" \
        --argjson dlm "$dlm" \
        --argjson skipBackup "$SKIP_BACKUP" \
        --argjson skipDlm "$SKIP_DLM" \
        '{
          accountId: $accountId,
          region: $region,
          profile: (if $profile == "" then null else $profile end),
          platform: $platform,
          generatedAt: $generatedAt,
          options: {
            skipBackup: $skipBackup,
            skipDlm: $skipDlm
          },
          dlmPolicies: $dlm,
          instances: $instances
        }'
}

print_table() {
    local summary="$1"
    printf '%s' "$summary" | jq -r '
      def tags_flat:
        to_entries | map("\(.key)=\(.value)") | join("; ");

      "Account: \(.accountId)",
      "Region:  \(.region)",
      "Platform:\(.platform)",
      "",
      (
        .instances[] |
        (
          "══════════════════════════════════════════════════════════",
          " Instance: \(.instanceId)",
          "══════════════════════════════════════════════════════════",
          "  found:   \(.found)",
          "  state:   \(.state // "n/a")",
          "  type:    \(.instanceType // "n/a")",
          "  az:      \(.availabilityZone // "n/a")",
          "  launch:  \(.launchTime // "n/a")",
          "  tags:    \(.tags | tags_flat)",
          (if (.notes | length) > 0 then "  notes:   \(.notes | join("; "))" else empty end),
          "",
          "  Volumes (\(.volumes | length)):",
          (if (.volumes | length) == 0 then "    (none)"
           else .volumes[] |
             "    - \(.volumeId) size=\(.size)GiB state=\(.state) leftover=\(.leftover) deleteOnTermination=\(.deleteOnTermination // "n/a") device=\(.device // "n/a") tags=\(.tags | tags_flat) match=\(.matchReason | join(","))"
           end),
          "",
          "  Snapshots (\(.snapshots | length)):",
          (if (.snapshots | length) == 0 then "    (none)"
           else .snapshots[] |
             "    - \(.snapshotId) volume=\(.volumeId // "n/a") state=\(.state) start=\(.startTime) size=\(.volumeSize)GiB tags=\(.tags | tags_flat) match=\(.matchReason | join(","))"
           end),
          "",
          "  AMIs (\(.amis | length)):",
          (if (.amis | length) == 0 then "    (none)"
           else .amis[] |
             "    - \(.imageId) name=\(.name // "n/a") state=\(.state) created=\(.creationDate) snapshots=\(.snapshotIds | join(",")) tags=\(.tags | tags_flat) match=\(.matchReason | join(","))"
           end),
          "",
          "  AWS Backup recovery points (\(.backupRecoveryPoints | length)):",
          (if (.backupRecoveryPoints | length) == 0 then "    (none)"
           else .backupRecoveryPoints[] |
             "    - vault=\(.vaultName) status=\(.status) created=\(.creationDate) resource=\(.resourceArn)"
           end),
          ""
        )
      ),
      "DLM policies (\(.dlmPolicies | length)):",
      (if (.dlmPolicies | length) == 0 then "  (none or skipped)"
       else .dlmPolicies[] | "  - \(.policyId) state=\(.state) type=\(.policyType // "n/a") desc=\(.description // "")"
       end)
    '
}

write_csv_reports() {
    local summary="$1"
    local dir="$2"

    printf '%s' "$summary" | jq -r '
      ["instanceId","found","state","instanceType","availabilityZone","launchTime","tags"],
      (.instances[] | [
        .instanceId,
        (.found|tostring),
        (.state // ""),
        (.instanceType // ""),
        (.availabilityZone // ""),
        (.launchTime // ""),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    ' > "$dir/instances.csv"

    printf '%s' "$summary" | jq -r '
      ["instanceId","volumeId","size","volumeType","state","availabilityZone","createTime","device","deleteOnTermination","leftover","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .volumes[] | [
        $iid,
        .volumeId,
        (.size|tostring),
        (.volumeType // ""),
        (.state // ""),
        (.availabilityZone // ""),
        (.createTime // ""),
        (.device // ""),
        (.deleteOnTermination // "" | tostring),
        (.leftover|tostring),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    ' > "$dir/volumes.csv"

    printf '%s' "$summary" | jq -r '
      ["instanceId","snapshotId","volumeId","state","startTime","volumeSize","description","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .snapshots[] | [
        $iid,
        .snapshotId,
        (.volumeId // ""),
        (.state // ""),
        (.startTime // ""),
        (.volumeSize|tostring),
        (.description // ""),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    ' > "$dir/snapshots.csv"

    printf '%s' "$summary" | jq -r '
      ["instanceId","imageId","name","state","creationDate","rootDeviceType","snapshotIds","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .amis[] | [
        $iid,
        .imageId,
        (.name // ""),
        (.state // ""),
        (.creationDate // ""),
        (.rootDeviceType // ""),
        (.snapshotIds | join("|")),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    ' > "$dir/amis.csv"

    printf '%s' "$summary" | jq -r '
      ["instanceId","vaultName","recoveryPointArn","resourceArn","resourceType","creationDate","completionDate","status"],
      (.instances[] | .instanceId as $iid | .backupRecoveryPoints[] | [
        $iid,
        .vaultName,
        .recoveryPointArn,
        .resourceArn,
        (.resourceType // ""),
        (.creationDate // ""),
        (.completionDate // ""),
        (.status // "")
      ]) | @csv
    ' > "$dir/backup-recovery-points.csv"

    info "Wrote $dir/instances.csv"
    info "Wrote $dir/volumes.csv"
    info "Wrote $dir/snapshots.csv"
    info "Wrote $dir/amis.csv"
    info "Wrote $dir/backup-recovery-points.csv"
}

print_csv_stdout() {
    local summary="$1"
    echo "# instances.csv"
    printf '%s' "$summary" | jq -r '
      ["instanceId","found","state","instanceType","availabilityZone","launchTime","tags"],
      (.instances[] | [
        .instanceId,
        (.found|tostring),
        (.state // ""),
        (.instanceType // ""),
        (.availabilityZone // ""),
        (.launchTime // ""),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    '
    echo ""
    echo "# volumes.csv"
    printf '%s' "$summary" | jq -r '
      ["instanceId","volumeId","size","volumeType","state","availabilityZone","createTime","device","deleteOnTermination","leftover","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .volumes[] | [
        $iid,
        .volumeId,
        (.size|tostring),
        (.volumeType // ""),
        (.state // ""),
        (.availabilityZone // ""),
        (.createTime // ""),
        (.device // ""),
        (.deleteOnTermination // "" | tostring),
        (.leftover|tostring),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    '
    echo ""
    echo "# snapshots.csv"
    printf '%s' "$summary" | jq -r '
      ["instanceId","snapshotId","volumeId","state","startTime","volumeSize","description","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .snapshots[] | [
        $iid,
        .snapshotId,
        (.volumeId // ""),
        (.state // ""),
        (.startTime // ""),
        (.volumeSize|tostring),
        (.description // ""),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    '
    echo ""
    echo "# amis.csv"
    printf '%s' "$summary" | jq -r '
      ["instanceId","imageId","name","state","creationDate","rootDeviceType","snapshotIds","matchReason","tags"],
      (.instances[] | .instanceId as $iid | .amis[] | [
        $iid,
        .imageId,
        (.name // ""),
        (.state // ""),
        (.creationDate // ""),
        (.rootDeviceType // ""),
        (.snapshotIds | join("|")),
        (.matchReason | join("|")),
        (.tags | to_entries | map("\(.key)=\(.value)") | join(";"))
      ]) | @csv
    '
    echo ""
    echo "# backup-recovery-points.csv"
    printf '%s' "$summary" | jq -r '
      ["instanceId","vaultName","recoveryPointArn","resourceArn","resourceType","creationDate","completionDate","status"],
      (.instances[] | .instanceId as $iid | .backupRecoveryPoints[] | [
        $iid,
        .vaultName,
        .recoveryPointArn,
        .resourceArn,
        (.resourceType // ""),
        (.creationDate // ""),
        (.completionDate // ""),
        (.status // "")
      ]) | @csv
    '
}

print_banner() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║     EC2 INSTANCE BACKUP / ELIMINATION INVENTORY        ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
}

main() {
    print_banner
    detect_platform
    info "Platform: $PLATFORM"

    check_dependencies

    [[ -n "$PROFILE" ]] && PROFILE_ARG="--profile $PROFILE"
    [[ -n "$REGION" ]] && REGION_ARG="--region $REGION"

    check_aws_auth

    info "Instance IDs: ${INSTANCE_IDS[*]}"
    info "Format: $FORMAT"

    if [[ "$REPORT" = true ]]; then
        if [[ -z "$REPORT_DIR" ]]; then
            REPORT_DIR="report/ec2-backup-inventory-$(date +%Y%m%d-%H%M%S)"
        fi
        REPORT_PATH="$REPORT_DIR"
        mkdir -p "$REPORT_PATH"
        info "Report directory: $REPORT_PATH"
    fi

    local summary
    summary="$(build_summary)"

    if [[ "$REPORT" = true ]]; then
        printf '%s\n' "$(printf '%s' "$summary" | jq '.')" > "$REPORT_PATH/summary.json"
        info "Wrote $REPORT_PATH/summary.json"
        write_csv_reports "$summary" "$REPORT_PATH"
    fi

    case "$FORMAT" in
        table)
            print_table "$summary"
            ;;
        json)
            printf '%s\n' "$(printf '%s' "$summary" | jq '.')"
            ;;
        csv)
            if [[ "$REPORT" = true ]]; then
                info "CSV files written under $REPORT_PATH (stdout suppressed to avoid duplication)"
            else
                print_csv_stdout "$summary"
            fi
            ;;
    esac

    echo ""
    success "Inventory complete (read-only; no changes were made)"
    info "See ec2/ec2-elimination.md for the elimination checklist"
    echo ""
}

main "$@"
