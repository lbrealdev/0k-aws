#!/bin/bash

set -euo pipefail

# Array to track generated reports
generated=()

TIMESTAMP=$(date '+%Y%m%d%H%M%S')
REPORT_DIR="aws_dev_report_${TIMESTAMP}"

echo "###########################################"
echo "#   AWS Developer Tools Report Generator  #"
echo "###########################################"
echo ""

# Check AWS credentials and retrieve account
if ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account' 2>/dev/null); then
  AWS_ACCOUNT="$ACCOUNT"
  REPORT_SUFFIX="${AWS_ACCOUNT}_${TIMESTAMP}.csv"
  mkdir -p "$REPORT_DIR"
else
  echo "Error: Invalid or missing AWS credentials/access keys."
  exit 1
fi

# AWS CodeCommit
# alias: aws-cc

if aws codecommit list-repositories > /dev/null 2>&1; then
  has_codecommit_repos=$(aws codecommit list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')
else
  echo "Warning: Insufficient permissions to access CodeCommit. Skipping report."
  has_codecommit_repos="access_denied"
fi

if [ "$has_codecommit_repos" == "not empty" ]; then
  echo "Generating report for AWS CodeCommit repositories..."
  aws codecommit list-repositories | jq -r '["NAME", "ID"], (.repositories[] | [.repositoryName, .repositoryId]) | @csv' > "$REPORT_DIR/aws-cc-$REPORT_SUFFIX"
  generated+=("aws-cc-$REPORT_SUFFIX")
elif [ "$has_codecommit_repos" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  echo "No repositories found in AWS CodeCommit."
fi

# AWS CodeArtifact
# alias: aws-ca

if aws codeartifact list-repositories > /dev/null 2>&1; then
  has_codeartifact_repos=$(aws codeartifact list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')
else
  echo "Warning: Insufficient permissions to access CodeArtifact. Skipping report."
  has_codeartifact_repos="access_denied"
fi

if [ "$has_codeartifact_repos" == "not empty" ]; then
  echo "Generating report for AWS CodeArtifact repositories..."
  aws codeartifact list-repositories | jq -r '["NAME", "DOMAIN", "DESCRIPTION"], (.repositories[] | [.name, .domainName, .description]) | @csv' > "$REPORT_DIR/aws-ca-$REPORT_SUFFIX"
  generated+=("aws-ca-$REPORT_SUFFIX")
elif [ "$has_codeartifact_repos" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  echo "No repositories found in AWS CodeArtifact."
fi

# AWS CodeBuild
# alias: aws-cb

if aws codebuild list-projects > /dev/null 2>&1; then
  has_codebuild_projects=$(aws codebuild list-projects | jq -r 'if (.projects | length > 0) then "not empty" else "empty" end')
else
  echo "Warning: Insufficient permissions to access CodeBuild. Skipping report."
  has_codebuild_projects="access_denied"
fi

if [ "$has_codebuild_projects" == "not empty" ]; then
  echo "Generating report for AWS CodeBuild projects..."
  aws codebuild list-projects | jq -r '["NAME"], (.projects[] | [.]) | @csv' > "$REPORT_DIR/aws-cb-$REPORT_SUFFIX"
  generated+=("aws-cb-$REPORT_SUFFIX")
elif [ "$has_codebuild_projects" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  echo "No projects found in AWS CodeBuild."
fi

# AWS CodeDeploy
# alias: aws-cd

if aws deploy list-applications > /dev/null 2>&1; then
  has_codedeploy_applications=$(aws deploy list-applications | jq -r 'if (.applications | length > 0) then "not empty" else "empty" end')
else
  echo "Warning: Insufficient permissions to access CodeDeploy. Skipping report."
  has_codedeploy_applications="access_denied"
fi

if [ "$has_codedeploy_applications" == "not empty" ]; then
  echo "Generating report for AWS CodeDeploy applications..."
  aws deploy list-applications | jq -r '["NAME"], (.applications[] | [.]) | @csv' > "$REPORT_DIR/aws-cd-$REPORT_SUFFIX"
  generated+=("aws-cd-$REPORT_SUFFIX")
elif [ "$has_codedeploy_applications" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  echo "No applications found in AWS CodeDeploy."
fi

# AWS CodePipeline
# alias: aws-cp

if aws codepipeline list-pipelines > /dev/null 2>&1; then
  has_codepipeline_pipelines=$(aws codepipeline list-pipelines | jq -r 'if (.pipelines | length > 0) then "not empty" else "empty" end')
else
  echo "Warning: Insufficient permissions to access CodePipeline. Skipping report."
  has_codepipeline_pipelines="access_denied"
fi

if [ "$has_codepipeline_pipelines" == "not empty" ]; then
  echo "Generating report for AWS CodePipeline pipelines..."
  aws codepipeline list-pipelines | jq -r '["NAME", "VERSION", "TYPE", "CREATED"], (.pipelines[] | [.name, .version, .pipelineType, .created]) | @csv' > "$REPORT_DIR/aws-cp-$REPORT_SUFFIX"
  generated+=("aws-cp-$REPORT_SUFFIX")
elif [ "$has_codepipeline_pipelines" == "access_denied" ]; then
  # Report skipped due to permissions
  :
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
  echo "No reports were generated."
fi

echo ""
echo "Process completed."
