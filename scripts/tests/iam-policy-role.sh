#!/bin/bash
# scripts/tests/iam-policy-role.sh - create-policy is sent as --cli-input-json.
#
# Stubs `aws` so attach never hits the network. Asserts create-policy input
# JSON (Path, PolicyDocument, Tags), that no aws argument starts with / or
# file://, that MSYS path-conversion env is unset, and that a pretty-printed
# file whose raw size is over 6144 is accepted when compacted form is under
# the cap.

set -uo pipefail

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Probe aws-iam-policy-role.sh attach: create-policy uses --cli-input-json.

Options:
  --help, -h         Show this help message

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Error: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/aws-iam-policy-role.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin"
export AWS_STUB_LOG="$TMP/aws.log"
: > "$AWS_STUB_LOG"

cat > "$TMP/bin/aws" <<'STUB'
#!/bin/bash
jq -nc \
    --arg no_pathconv "${MSYS_NO_PATHCONV-}" \
    --arg arg_conv_excl "${MSYS2_ARG_CONV_EXCL-}" \
    --args \
    '{args:$ARGS.positional,MSYS_NO_PATHCONV:$no_pathconv,MSYS2_ARG_CONV_EXCL:$arg_conv_excl}' \
    -- "$@" >> "${AWS_STUB_LOG}"

op=""
for a in "$@"; do
    case "$a" in
        get-caller-identity|get-role|get-policy|create-policy)
            op="$a"
            break
            ;;
    esac
done

case "$op" in
    get-caller-identity)
        printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/stub","UserId":"AIDASTUB"}'
        ;;
    get-role)
        printf '%s\n' '{}'
        ;;
    get-policy)
        printf 'An error occurred (NoSuchEntity) when calling the GetPolicy operation: not found\n' >&2
        exit 254
        ;;
    create-policy)
        printf '%s\n' '{"Policy":{"Arn":"arn:aws:iam::123456789012:policy/extra"}}'
        ;;
    *)
        printf '%s\n' '{}'
        ;;
esac
STUB
chmod +x "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE
unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
export AWS_CONFIG_FILE="$TMP/config"
: > "$AWS_CONFIG_FILE"

passed=0
failed=0
ok()  { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }

cli_input_from_log() {
    jq -r '
        select(.args | index("create-policy") != null)
        | .args[.args | index("--cli-input-json") + 1] // empty
    ' "$AWS_STUB_LOG" | tail -n 1
}

assert_create_policy_input() {
    local expected_path="$1"
    local compact="$2"
    local input
    input="$(cli_input_from_log)"
    if [[ -z "$input" ]]; then
        bad "create-policy --cli-input-json was not logged"
        return
    fi
    ok "create-policy --cli-input-json was logged"
    if printf '%s' "$input" | jq -e \
        --arg p "$expected_path" \
        --arg doc "$compact" \
        '.Path == $p
         and .PolicyDocument == $doc
         and (.Tags | any(.Key == "toggle" and .Value == "extra"))' \
        >/dev/null; then
        ok "create-policy input Path=$expected_path, PolicyDocument matches, tags present"
    else
        bad "create-policy --cli-input-json mismatch for Path=$expected_path"
        printf '%s\n' "$input"
    fi
}

assert_no_slash_or_file_args() {
    local hits
    hits=$(jq -s '[.[] | .args[] | select(startswith("/") or startswith("file://"))] | length' "$AWS_STUB_LOG")
    if [[ "$hits" -eq 0 ]]; then
        ok "no aws argument starts with / or file://"
    else
        bad "aws arguments starting with / or file://"
        jq -s '[.[] | .args[] | select(startswith("/") or startswith("file://"))]' "$AWS_STUB_LOG"
    fi
}

assert_msys_env_unset() {
    local n setn
    n=$(jq -s 'length' "$AWS_STUB_LOG")
    if [[ "$n" -eq 0 ]]; then
        bad "no aws calls logged"
        return
    fi
    setn=$(jq -s '[.[] | select(.MSYS_NO_PATHCONV != "" or .MSYS2_ARG_CONV_EXCL != "")] | length' "$AWS_STUB_LOG")
    if [[ "$setn" -eq 0 ]]; then
        ok "MSYS_NO_PATHCONV and MSYS2_ARG_CONV_EXCL unset on all $n aws calls"
    else
        bad "MSYS env set on $setn of $n aws calls"
    fi
}

write_pretty_policy() {
    cat > "$1" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF
}

write_padded_policy() {
    {
        printf '{\n  "Version": "2012-10-17",\n  "Statement": [\n    {\n'
        printf '      "Effect": "Allow",\n'
        printf '      "Action": "sts:GetCallerIdentity",\n'
        printf '      "Resource": "*"\n'
        printf '    }\n  ]\n'
        printf '%*s\n' 7000 ''
        printf '}\n'
    } > "$1"
}

run_attach() {
    local file="$1"
    shift
    ( cd "$TMP" && bash "$SCRIPT" attach \
        --profile stub \
        --role-name agent \
        --policy-name extra \
        --tag toggle=extra \
        --policy-file "$file" \
        "$@" )
}

printf '== iam policy-role probe ==\n'

# 1) Pretty-printed file: create-policy input is JSON, not file:// or --path.
write_pretty_policy "$TMP/policy.json"
: > "$AWS_STUB_LOG"
out="$(run_attach policy.json 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "attach pretty-printed policy: exit 0"
else
    bad "attach pretty-printed policy: exit $rc"
    printf '%s\n' "$out"
fi

compact="$(jq -c '.' "$TMP/policy.json")"
assert_create_policy_input "/" "$compact"
assert_no_slash_or_file_args
assert_msys_env_unset

# 2) Pretty-printed file: raw size > 6144, compacted size under the cap.
write_padded_policy "$TMP/padded.json"
raw_len="$(wc -c < "$TMP/padded.json")"
pad_compact="$(jq -c '.' "$TMP/padded.json")"
compact_len="${#pad_compact}"

if [[ "$raw_len" -gt 6144 && "$compact_len" -lt 6144 ]]; then
    ok "padded fixture: raw $raw_len > 6144, compacted $compact_len < 6144"
else
    bad "padded fixture sizes: raw=$raw_len compacted=$compact_len"
fi

: > "$AWS_STUB_LOG"
out="$(run_attach padded.json 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "attach padded policy: exit 0 (compacted form accepted)"
else
    bad "attach padded policy: exit $rc (should accept compacted form under 6144)"
    printf '%s\n' "$out"
fi

if grep -q 'exceeds 6144' <<<"$out"; then
    bad "attach padded policy: size check refused a valid compacted document"
else
    ok "attach padded policy: size check did not refuse"
fi

assert_create_policy_input "/" "$pad_compact"
assert_no_slash_or_file_args
assert_msys_env_unset

# 3) --path /team/ is inside --cli-input-json, not a bare aws argument.
: > "$AWS_STUB_LOG"
out="$(run_attach policy.json --path /team/ 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "attach --path /team/: exit 0"
else
    bad "attach --path /team/: exit $rc"
    printf '%s\n' "$out"
fi

assert_create_policy_input "/team/" "$compact"
assert_no_slash_or_file_args
assert_msys_env_unset

printf '\nPassed: %d  Failed: %d\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
