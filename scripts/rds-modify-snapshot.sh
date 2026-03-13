#!/usr/bin/env bash

set -euo pipefail

check_dependencies() {
  if ! command -v aws > /dev/null; then
    echo "Error: aws-cli is not installed or not in PATH."
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

usage() {
  echo "Usage: $0 --snapshot-name <snapshot-name> --option-group <option-group-name>"
  echo ""
  echo "Modifies an RDS DB snapshot by changing its option group."
  echo ""
  echo "Required arguments:"
  echo "  --snapshot-name    The identifier of the DB snapshot to modify"
  echo "  --option-group     The option group to associate with the DB snapshot"
  echo ""
  echo "Example:"
  echo "  $0 --snapshot-name my-db-snapshot --option-group my-option-group"
}

# Parse arguments
SNAPSHOT_NAME=""
OPTION_GROUP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --snapshot-name)
      SNAPSHOT_NAME="$2"
      shift 2
      ;;
    --option-group)
      OPTION_GROUP="$2"
      shift 2
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
if [[ -z "$SNAPSHOT_NAME" ]]; then
  echo "Error: --snapshot-name is required"
  usage
  exit 1
fi

if [[ -z "$OPTION_GROUP" ]]; then
  echo "Error: --option-group is required"
  usage
  exit 1
fi

main() {
  echo "################################"
  echo "#   RDS SNAPSHOT MODIFICATION  #"
  echo "################################"
  echo ""
  
  check_dependencies
  check_aws_auth
  
  echo ""
  echo "Modifying DB snapshot '$SNAPSHOT_NAME' with option group '$OPTION_GROUP'..."
  
  # Execute the AWS CLI command
  aws rds modify-db-snapshot \
    --db-snapshot-identifier "$SNAPSHOT_NAME" \
    --option-group-name "$OPTION_GROUP"
  
  echo ""
  echo "DB snapshot modification initiated successfully."
  echo "Use 'aws rds describe-db-snapshots --db-snapshot-identifier $SNAPSHOT_NAME' to check status."
}

main