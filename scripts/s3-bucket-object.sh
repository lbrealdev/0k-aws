#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

List S3 buckets and object counts in the current AWS account (read-only).

Options:
  --help, -h         Show this help message

EOF
}

check_dependencies() {
  if ! command -v aws > /dev/null; then
    echo "Error: aws-cli is not installed or not in PATH."
    exit 1
  fi

  if ! command -v jq > /dev/null; then
    echo "Error: jq is not installed or not in PATH."
    exit 1
  fi
}

check_aws_auth() {
  if ! ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
    echo "Error: invalid or missing AWS credentials/access keys."
    exit 1
  else
    AWS_ACCOUNT="$ACCOUNT"
    AWS_REGION=$(aws configure get region)

    echo "AWS ACCOUNT: $AWS_ACCOUNT"
    echo "AWS REGION: ${AWS_REGION:-not set}"
  fi
}

get_bucket_objects() {
  echo ""
  echo "Getting s3 buckets..."

  S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" | jq -r '.[]')

  for bucket in $S3_BUCKETS; do
    objects_count=$(aws s3api list-objects --bucket "$bucket" --query 'Contents[].Key | length(@)')
    echo "Bucket: $bucket"
    echo "Objects: $objects_count"
  done
}

main() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  echo "################################"
  echo "#    AWS S3 BUCKETS OBJECTS    #"
  echo "################################"
  echo ""

  check_dependencies
  check_aws_auth
  get_bucket_objects
}

main "$@"
