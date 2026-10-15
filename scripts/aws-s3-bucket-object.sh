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

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

List S3 buckets and object counts in the current AWS account (read-only).

Options:
  -q, --quiet        Suppress the header and non-error status rows
  -h, --help         Show this help message

Examples:
  $0
EOF
}

error() { ui_always "$(ui_color red)[ERROR]$(ui_color reset) $*"; }
info()  { ui_row "$(ui_color blue)[INFO]$(ui_color reset) $*"; }

check_dependencies() {
  if ! command -v aws > /dev/null; then
    error "aws-cli is not installed or not in PATH."
    exit 1
  fi

  if ! command -v jq > /dev/null; then
    error "jq is not installed or not in PATH."
    exit 1
  fi
}

check_aws_auth() {
  if ! ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
    error "invalid or missing AWS credentials/access keys."
    exit 1
  else
    AWS_ACCOUNT="$ACCOUNT"
    AWS_REGION=$(aws configure get region)

    info "AWS ACCOUNT: $AWS_ACCOUNT"
    info "AWS REGION: ${AWS_REGION:-not set}"
  fi
}

get_bucket_objects() {
  info "Getting s3 buckets..."

  S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" | jq -r '.[]')

  # Bucket names are newline-separated; word splitting is intended here.
  # shellcheck disable=SC2086
  for bucket in $S3_BUCKETS; do
    objects_count=$(aws s3api list-objects --bucket "$bucket" --query 'Contents[].Key | length(@)')
    ui_out "Bucket: $bucket"
    ui_out "Objects: $objects_count"
  done
}

main() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -q|--quiet)
        ui_quiet
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  ui_header "s3-bucket-object: S3 buckets and object counts (read-only)"

  check_dependencies
  check_aws_auth
  get_bucket_objects
}

main "$@"
