#!/bin/bash

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

# Write: attach creates a tagged customer managed policy from a JSON file and
# attaches it to one role. detach removes that attachment and deletes the
# policy when the tag matches and no other entity is attached.
# Exit codes: 0 ok, 1 usage, 2 AWS error or safety refusal.

AWS_ENV_VARS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)
export AWS_PAGER=""

ACTION=""
PROFILE=""
ROLE_NAME=""
POLICY_NAME=""
POLICY_FILE=""
TAG_RAW=""
TAG_KEY=""
TAG_VALUE=""
DESCRIPTION=""
POLICY_PATH="/"
REGION="us-east-1"
DRY_RUN=false

ACCOUNT=""
PARTITION=""
POLICY_ARN=""
POLICY_EXISTS=false
POLICY_JSON=""
AWS_BODY=""
AWS_RC=0

usage() {
    local prog
    prog=$(basename -- "$0")
    cat << EOF
Usage: ${prog} attach [OPTIONS]
       ${prog} detach [OPTIONS]

Create a tagged customer managed policy and attach it to a role,
or detach that policy and delete it.

Required:
      --profile NAME     Named profile. Env keys are refused
      --role-name NAME   IAM role
      --policy-name NAME Customer managed policy name
      --tag KEY=VALUE    Identifier tag. Mismatch refuses

attach also requires:
      --policy-file PATH Policy document JSON

Options:
      --region REGION    Signing region (default: us-east-1)
      --description TEXT Set when the policy is created
      --path PATH        Policy path (default: /)
      --dry-run          Plan on stdout; write nothing
  -q, --quiet            Drop banner and non-error rows
  -h, --help             Show this help

On detach, the policy is deleted only when the tag matches and no
other user, group, or role is attached. An existing policy is not
rewritten; if the file differs, attach stops.

Examples:
  ${prog} attach --profile dev --role-name agent \\
      --policy-name extra --tag toggle=extra \\
      --policy-file policy.json --dry-run
  ${prog} detach --profile dev --role-name agent \\
      --policy-name extra --tag toggle=extra --dry-run
EOF
}

error() { ui_always "$(ui_color red)[ERROR]$(ui_color reset) $*"; }
warn()  { ui_always "$(ui_color yellow)[WARN]$(ui_color reset)  $*"; }
info()  { ui_row "$(ui_color blue)[INFO]$(ui_color reset)  $*"; }

print_banner() {
    ui_banner <<'EOF'

aws-iam-policy-role
--------------------

EOF
}

plan() {
    if [[ "$DRY_RUN" == true ]]; then
        ui_out "dry-run $*"
    else
        ui_out "$*"
    fi
}

need_value() {
    local flag="$1"
    if [[ -z "${2:-}" || "$2" == --* ]]; then
        error "Option ${flag} requires a value"
        exit 1
    fi
}

refuse_env_credentials() {
    local found=()
    local var
    for var in "${AWS_ENV_VARS[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            found+=("$var")
        fi
    done
    if [[ ${#found[@]} -gt 0 ]]; then
        error "named profile only; unset: ${found[*]}"
        exit 2
    fi
}

check_dependencies() {
    if ! command -v aws >/dev/null 2>&1; then
        error "aws CLI is not installed or not in PATH"
        exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is not installed or not in PATH"
        exit 2
    fi
}

run_aws() {
    local err out rc
    err=$(mktemp)
    out=$(mktemp)
    set +e
    aws --profile "$PROFILE" --region "$REGION" "$@" >"$out" 2>"$err"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        error "aws command failed"
        cat "$err" >&2
        rm -f "$err" "$out"
        exit 2
    fi
    AWS_BODY=$(<"$out")
    AWS_RC=0
    rm -f "$err" "$out"
}

# AWS_RC=10 when IAM returns NoSuchEntity. Any other failure exits 2.
run_aws_soft() {
    local err out rc
    err=$(mktemp)
    out=$(mktemp)
    set +e
    aws --profile "$PROFILE" --region "$REGION" "$@" >"$out" 2>"$err"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if grep -q 'NoSuchEntity' "$err"; then
            AWS_BODY=""
            AWS_RC=10
            rm -f "$err" "$out"
            return 0
        fi
        error "aws command failed"
        cat "$err" >&2
        rm -f "$err" "$out"
        exit 2
    fi
    AWS_BODY=$(<"$out")
    AWS_RC=0
    rm -f "$err" "$out"
}

refuse_truncated() {
    if jq -e '.IsTruncated == true' >/dev/null 2>&1 <<<"$AWS_BODY"; then
        error "IAM result was truncated; refusing to continue"
        exit 2
    fi
}

load_identity() {
    run_aws sts get-caller-identity --output json
    ACCOUNT=$(jq -r '.Account // empty' <<<"$AWS_BODY")
    PARTITION=$(jq -r '.Arn | split(":")[1] // empty' <<<"$AWS_BODY")
    if [[ ! "$ACCOUNT" =~ ^[0-9]{12}$ || -z "$PARTITION" ]]; then
        error "could not read account id from STS"
        exit 2
    fi
    POLICY_ARN="arn:${PARTITION}:iam::${ACCOUNT}:policy${POLICY_PATH}${POLICY_NAME}"
}

ensure_role() {
    run_aws iam get-role --role-name "$ROLE_NAME" --output json >/dev/null
}

lookup_policy() {
    run_aws_soft iam get-policy --policy-arn "$POLICY_ARN" --output json
    if [[ "$AWS_RC" -eq 10 ]]; then
        POLICY_EXISTS=false
        POLICY_JSON=""
        return 0
    fi
    POLICY_EXISTS=true
    POLICY_JSON="$AWS_BODY"
}

require_tag_match() {
    local ok
    run_aws iam list-policy-tags --policy-arn "$POLICY_ARN" --output json
    refuse_truncated
    ok=$(jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" \
        '.Tags // [] | any(.Key == $k and .Value == $v)' <<<"$AWS_BODY")
    if [[ "$ok" != "true" ]]; then
        error "policy tag does not match; refusing to touch it"
        exit 2
    fi
}

require_same_document() {
    local ver local_norm remote_norm
    ver=$(jq -r '.Policy.DefaultVersionId // empty' <<<"$POLICY_JSON")
    if [[ -z "$ver" ]]; then
        error "policy has no default version"
        exit 2
    fi
    run_aws iam get-policy-version \
        --policy-arn "$POLICY_ARN" \
        --version-id "$ver" \
        --output json
    local_norm=$(jq -c -S '.' "$POLICY_FILE")
    remote_norm=$(jq -c -S '.PolicyVersion.Document' <<<"$AWS_BODY")
    if [[ "$local_norm" != "$remote_norm" ]]; then
        error "policy already exists and the document differs; detach it first"
        exit 2
    fi
}

role_is_attached() {
    local ok
    run_aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json
    refuse_truncated
    ok=$(jq -r --arg arn "$POLICY_ARN" \
        '.AttachedPolicies // [] | any(.PolicyArn == $arn)' <<<"$AWS_BODY")
    [[ "$ok" == "true" ]]
}

create_policy() {
    local tags_json doc input
    tags_json=$(jq -nc --arg k "$TAG_KEY" --arg v "$TAG_VALUE" \
        '[{Key:$k,Value:$v}]')
    doc=$(jq -c '.' "$POLICY_FILE")
    input=$(jq -nc \
        --arg name "$POLICY_NAME" \
        --arg path "$POLICY_PATH" \
        --arg doc "$doc" \
        --argjson tags "$tags_json" \
        '{PolicyName:$name,Path:$path,PolicyDocument:$doc,Tags:$tags}')
    if [[ -n "$DESCRIPTION" ]]; then
        input=$(jq -c --arg d "$DESCRIPTION" '. + {Description:$d}' <<<"$input")
    fi
    run_aws iam create-policy --cli-input-json "$input" --output json
    POLICY_ARN=$(jq -r '.Policy.Arn // empty' <<<"$AWS_BODY")
    if [[ -z "$POLICY_ARN" || "$POLICY_ARN" == "null" ]]; then
        error "create-policy did not return an ARN"
        exit 2
    fi
    plan "create-policy ${POLICY_ARN}"
}

attach_policy() {
    run_aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN" \
        --output json
    plan "attach-role-policy ${ROLE_NAME} ${POLICY_ARN}"
}

do_attach() {
    if [[ "$POLICY_EXISTS" == false ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            plan "create-policy ${POLICY_ARN}"
            plan "attach-role-policy ${ROLE_NAME} ${POLICY_ARN}"
            return 0
        fi
        create_policy
        attach_policy
        return 0
    fi

    require_tag_match
    require_same_document
    if role_is_attached; then
        ui_out "already-attached ${ROLE_NAME} ${POLICY_ARN}"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        plan "attach-role-policy ${ROLE_NAME} ${POLICY_ARN}"
        return 0
    fi
    attach_policy
}

other_entities() {
    jq -r --arg role "$ROLE_NAME" '
        [
          (.PolicyRoles // [] | .[] | select(.RoleName != $role) | "role:" + .RoleName),
          (.PolicyUsers // [] | .[] | "user:" + .UserName),
          (.PolicyGroups // [] | .[] | "group:" + .GroupName)
        ] | .[]
    ' <<<"$AWS_BODY"
}

this_role_attached_entity() {
    jq -e --arg role "$ROLE_NAME" \
        '.PolicyRoles // [] | any(.RoleName == $role)' >/dev/null <<<"$AWS_BODY"
}

delete_policy() {
    local ver_json vid
    run_aws iam list-policy-versions --policy-arn "$POLICY_ARN" --output json
    ver_json="$AWS_BODY"
    while IFS= read -r vid; do
        [[ -z "$vid" ]] && continue
        run_aws iam delete-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$vid" \
            --output json
    done < <(jq -r '.Versions[]? | select(.IsDefaultVersion | not) | .VersionId' <<<"$ver_json")
    run_aws iam delete-policy --policy-arn "$POLICY_ARN" --output json
    plan "delete-policy ${POLICY_ARN}"
}

do_detach() {
    local entities attached ent
    if [[ "$POLICY_EXISTS" == false ]]; then
        ui_out "absent ${POLICY_NAME}"
        return 0
    fi

    require_tag_match
    run_aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --no-paginate --output json
    refuse_truncated
    entities=$(other_entities)
    if [[ -n "$entities" ]]; then
        error "policy is attached to other entities; not changing it"
        while IFS= read -r ent; do
            [[ -z "$ent" ]] && continue
            error "also attached: $(ui_esc_data "$ent")"
        done <<<"$entities"
        exit 2
    fi

    if this_role_attached_entity; then
        attached=true
    else
        attached=false
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$attached" == true ]]; then
            plan "detach-role-policy ${ROLE_NAME} ${POLICY_ARN}"
        fi
        plan "delete-policy ${POLICY_ARN}"
        return 0
    fi

    if [[ "$attached" == true ]]; then
        run_aws iam detach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "$POLICY_ARN" \
            --output json
        plan "detach-role-policy ${ROLE_NAME} ${POLICY_ARN}"
    fi
    delete_policy
}

if [[ $# -lt 1 ]]; then
    error "missing action: attach or detach"
    usage >&2
    exit 1
fi

case "$1" in
    attach|detach)
        ACTION="$1"
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        error "unknown action: $(ui_esc_data "$1")"
        usage >&2
        exit 1
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            need_value "$1" "${2:-}"
            PROFILE="$2"
            shift 2
            ;;
        --role-name)
            need_value "$1" "${2:-}"
            ROLE_NAME="$2"
            shift 2
            ;;
        --policy-name)
            need_value "$1" "${2:-}"
            POLICY_NAME="$2"
            shift 2
            ;;
        --policy-file)
            need_value "$1" "${2:-}"
            POLICY_FILE="$2"
            shift 2
            ;;
        --tag)
            need_value "$1" "${2:-}"
            TAG_RAW="$2"
            shift 2
            ;;
        --description)
            need_value "$1" "${2:-}"
            DESCRIPTION="$2"
            shift 2
            ;;
        --path)
            need_value "$1" "${2:-}"
            POLICY_PATH="$2"
            shift 2
            ;;
        --region)
            need_value "$1" "${2:-}"
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -q|--quiet)
            ui_quiet
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $(ui_esc_data "$1")"
            usage >&2
            exit 1
            ;;
    esac
done

main() {
    local name_re key_lc compact
    name_re='^[A-Za-z0-9+=,.@_-]+$'

    if [[ -z "$PROFILE" || -z "$ROLE_NAME" || -z "$POLICY_NAME" || -z "$TAG_RAW" ]]; then
        error "missing required option"
        usage >&2
        exit 1
    fi
    if [[ "$ACTION" == "attach" && -z "$POLICY_FILE" ]]; then
        error "attach requires --policy-file"
        usage >&2
        exit 1
    fi
    if [[ "$ACTION" == "detach" && -n "$POLICY_FILE" ]]; then
        error "detach does not take --policy-file"
        exit 1
    fi
    if [[ "$ACTION" == "detach" && -n "$DESCRIPTION" ]]; then
        error "detach does not take --description"
        exit 1
    fi
    if [[ ! "$ROLE_NAME" =~ $name_re || ${#ROLE_NAME} -gt 64 ]]; then
        error "invalid --role-name"
        exit 1
    fi
    if [[ ! "$POLICY_NAME" =~ $name_re || ${#POLICY_NAME} -gt 128 ]]; then
        error "invalid --policy-name"
        exit 1
    fi
    if [[ ! "$POLICY_PATH" =~ ^/([A-Za-z0-9+=,.@_-]+/)*$ ]]; then
        error "invalid --path (use / or /team/)"
        exit 1
    fi
    if [[ "$TAG_RAW" != *=* ]]; then
        error "--tag must be KEY=VALUE"
        exit 1
    fi
    TAG_KEY="${TAG_RAW%%=*}"
    TAG_VALUE="${TAG_RAW#*=}"
    if [[ -z "$TAG_KEY" || ${#TAG_KEY} -gt 128 || ${#TAG_VALUE} -gt 256 ]]; then
        error "invalid --tag"
        exit 1
    fi
    key_lc=$(printf '%s' "$TAG_KEY" | tr '[:upper:]' '[:lower:]')
    if [[ "$key_lc" == aws:* ]]; then
        error "--tag key must not start with aws:"
        exit 1
    fi
    if [[ -n "$DESCRIPTION" && ${#DESCRIPTION} -gt 1000 ]]; then
        error "--description is longer than 1000 characters"
        exit 1
    fi

    print_banner
    info "action: $(ui_esc_data "$ACTION")"
    info "profile: $(ui_esc_data "$PROFILE")"
    info "role: $(ui_esc_data "$ROLE_NAME")"
    info "policy: $(ui_esc_data "$POLICY_NAME")"
    info "tag: $(ui_esc_data "${TAG_KEY}=${TAG_VALUE}")"
    if [[ "$DRY_RUN" == true ]]; then
        warn "dry-run: no changes will be made"
    fi

    refuse_env_credentials
    check_dependencies

    if [[ "$ACTION" == "attach" ]]; then
        if [[ ! -f "$POLICY_FILE" ]]; then
            error "policy file not found: $(ui_esc_data "$POLICY_FILE")"
            exit 1
        fi
        if ! jq -e 'type == "object" and (.Statement | if type == "array" then length > 0 else type == "object" end)' \
            "$POLICY_FILE" >/dev/null; then
            error "policy file must be a JSON object with Statement"
            exit 1
        fi
        compact=$(jq -c '.' "$POLICY_FILE")
        if [[ ${#compact} -gt 6144 ]]; then
            error "compacted policy document exceeds 6144 characters"
            exit 1
        fi
    fi

    load_identity
    ensure_role
    lookup_policy
    info "policy arn: $(ui_esc_data "$POLICY_ARN")"

    if [[ "$ACTION" == "attach" ]]; then
        do_attach
    else
        do_detach
    fi
}

main
