#!/bin/bash
# tests/ui-render.sh - presentation probe for the shared status layout.
#
# For each shell script it checks the four documented cases:
#   1. --help          plain, exit 0, no ANSI
#   2. piped output    no ANSI
#   3. NO_COLOR=1      no ANSI
#   4. --quiet         no ANSI, no banner/header
#
# It never touches the network: a stub `aws` on PATH fails fast, and
# scripts that read config get an empty AWS_CONFIG_FILE.

set -uo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ESC=$'\e['

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Stub AWS CLI so no script reaches the network.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/aws" <<'STUB'
#!/bin/bash
printf 'stub-aws: refusing to call AWS in tests\n' >&2
exit 1
STUB
chmod +x "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH"

# Keep config-based scripts hermetic.
export AWS_CONFIG_FILE="$TMP/config"
: > "$AWS_CONFIG_FILE"
unset AWS_PROFILE AWS_DEFAULT_PROFILE
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

passed=0
failed=0
ok()  { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; failed=$((failed + 1)); }

# script|banner-or-header marker|extra args to reach rendering
SCRIPTS=(
    "scripts/aws-sso-check.sh|__________ ____|--check-config"
    "scripts/aws-codecommit-gitconfig.sh|AWS CODECOMMIT GIT CONFIG SETUP|"
    "scripts/aws-devtools-report.sh|aws-dev-tools-report: CSV reports|"
    "scripts/aws-ec2-final-snapshot.sh|EC2 MANUAL / FINAL SNAPSHOTS|-i i-0123456789abcdef0"
    "scripts/aws-ec2-inventory.sh|ec2-inventory: read-only|-i i-0123456789abcdef0"
    "scripts/aws-iam-find-role.sh|find-iam-role: find an IAM role|dummy --profile p"
    "scripts/aws-account-list-resources.sh|list-resources: account resources|"
    "scripts/aws-rds-modify-snapshot.sh|RDS SNAPSHOT BATCH MODIFICATION|--source-option a --target-option b"
    "scripts/aws-rds-snapshot-age.sh|rds-snapshot-age: RDS snapshot ages|"
    "scripts/aws-s3-bucket-object.sh|s3-bucket-object: S3 buckets|"
    "scripts/aws-ec2-sg-audit.sh|sg-audit: security-group ingress|"
)

# Run a script from an unrelated CWD (also proves lib/ui.sh resolution).
run() {
    local script="$1"
    shift
    ( cd "$TMP" && bash "$ROOT/$script" "$@" 2>&1 )
}

has_ansi() { [[ "$1" == *"$ESC"* ]]; }

printf '== ui render probe ==\n'

for entry in "${SCRIPTS[@]}"; do
    IFS='|' read -r script marker args <<< "$entry"
    name="$(basename "$script")"
    read -r -a extra <<< "$args"

    # 1) --help: plain text, exit 0, no ANSI.
    help_out="$( run "$script" --help )"
    help_rc=$?
    if [[ "$help_rc" -eq 0 ]] && ! has_ansi "$help_out"; then
        ok "$name --help: exit 0, plain"
    else
        bad "$name --help: exit $help_rc or ANSI present"
    fi

    # 2) Output through a pipe: no ANSI, and the banner/header renders.
    pipe_out="$( run "$script" "${extra[@]+"${extra[@]}"}" )"
    if has_ansi "$pipe_out"; then
        bad "$name piped: ANSI leaked"
    else
        ok "$name piped: no ANSI"
    fi
    if [[ "$pipe_out" == *"$marker"* ]]; then
        ok "$name piped: banner/header rendered"
    else
        bad "$name piped: missing banner/header marker"
    fi

    # 3) NO_COLOR=1: no ANSI.
    nc_out="$( NO_COLOR=1 run "$script" "${extra[@]+"${extra[@]}"}" )"
    if has_ansi "$nc_out"; then
        bad "$name NO_COLOR=1: ANSI leaked"
    else
        ok "$name NO_COLOR=1: no ANSI"
    fi

    # 4) --quiet: no ANSI and the banner/header is gone.
    quiet_out="$( run "$script" "${extra[@]+"${extra[@]}"}" --quiet )"
    if has_ansi "$quiet_out"; then
        bad "$name --quiet: ANSI leaked"
    elif [[ "$quiet_out" == *"$marker"* ]]; then
        bad "$name --quiet: banner/header still printed"
    else
        ok "$name --quiet: no ANSI, no banner/header"
    fi
done

printf '\nPassed: %d  Failed: %d\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
