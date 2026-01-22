#!/bin/bash

set -euo pipefail

# Array to track generated reports
generated=()

AWS_ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
TIMESTAMP=$(date '+%Y%m%d%H%M%S')
REPORT_DIR="aws_dev_report_${TIMESTAMP}"
REPORT_SUFFIX="${AWS_ACCOUNT}_${TIMESTAMP}.csv"

mkdir -p "$REPORT_DIR"

# Check AWS credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "Error: Invalid or missing AWS credentials/access keys."
  exit 1
fi

echo "############################################"
echo "#   AWS Developer Tools Report Generator   #"
echo "############################################"
echo ""

# AWS CodeCommit
# alias: aws-cc

cc_repos=$(aws codecommit list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$cc_repos" == "not empty" ]; then
  echo "Generating report for AWS CodeCommit repositories..."
  aws codecommit list-repositories | jq -r '["NAME", "ID"], (.repositories[] | [.repositoryName, .repositoryId]) | @csv' > "$REPORT_DIR/aws-cc-$REPORT_SUFFIX"
  generated+=("aws-cc-$REPORT_SUFFIX")
else
  echo "No repositories found in AWS CodeCommit."
fi

# AWS CodeArtifact
# alias: aws-ca

ca_repos=$(aws codeartifact list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$ca_repos" == "not empty" ]; then
  echo "Generating report for AWS CodeArtifact repositories..."
  aws codeartifact list-repositories | jq -r '["NAME", "DOMAIN", "DESCRIPTION"], (.repositories[] | [.name, .domainName, .description]) | @csv' > "$REPORT_DIR/aws-ca-$REPORT_SUFFIX"
  generated+=("aws-ca-$REPORT_SUFFIX")
else
  echo "No repositories found in AWS CodeArtifact."
fi

# AWS CodeBuild
# alias: aws-cb

cb_projects=$(aws codebuild list-projects | jq -r 'if (.projects | length > 0) then "not empty" else "empty" end')

if [ "$cb_projects" == "not empty" ]; then
  echo "Generating report for AWS CodeBuild projects..."
  aws codebuild list-projects | jq -r '["NAME"], (.projects[] | [.]) | @csv' > "$REPORT_DIR/aws-cb-$REPORT_SUFFIX"
  generated+=("aws-cb-$REPORT_SUFFIX")
else
  echo "No projects found in AWS CodeBuild."
fi

# AWS CodeDeploy
# alias: aws-cd

cd_deployments=$(aws deploy list-applications | jq -r 'if (.applications | length > 0) then "not empty" else "empty" end')

if [ "$cd_deployments" == "not empty" ]; then
  echo "Generating report for AWS CodeDeploy applications..."
  aws deploy list-applications | jq -r '["NAME"], (.applications[] | [.]) | @csv' > "$REPORT_DIR/aws-cd-$REPORT_SUFFIX"
  generated+=("aws-cd-$REPORT_SUFFIX")
else
  echo "No applications found in AWS CodeDeploy."
fi

# AWS CodePipeline
# alias: aws-cp

cp_pipelines=$(aws codepipeline list-pipelines | jq -r 'if (.pipelines | length > 0) then "not empty" else "empty" end')

if [ "$cp_pipelines" == "not empty" ]; then
  echo "Generating report for AWS CodePipeline pipelines..."
  aws codepipeline list-pipelines | jq -r '["NAME", "VERSION", "TYPE", "CREATED"], (.pipelines[] | [.name, .version, .pipelineType, .created]) | @csv' > "$REPORT_DIR/aws-cp-$REPORT_SUFFIX"
  generated+=("aws-cp-$REPORT_SUFFIX")
else
  echo "No pipelines found in AWS CodePipeline."
fi

echo ""
echo "############################################"
echo ""

if [ ${#generated[@]} -gt 0 ]; then
  echo "Generated reports in directory: $REPORT_DIR"
  for report in "${generated[@]}"; do
    echo "  - $REPORT_DIR/$report"
  done
else
  echo "No reports generated."
fi

echo ""
echo "Report generation completed."
