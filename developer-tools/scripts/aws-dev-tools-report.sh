#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Array to track generated reports
generated=()

AWS_ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
TIMESTAMP=$(date '+%Y%d%m%H%M%S')
REPORT_SUFFIX="${AWS_ACCOUNT}_${TIMESTAMP}.csv"

# Check AWS credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo -e "${RED}Error: Invalid or missing AWS credentials/access keys.${NC}"
  exit 1
fi

echo -e "${BLUE}AWS Developer Tools Report Generator${NC}"
echo -e "${BLUE}====================================${NC}"

# AWS CodeCommit
# alias: aws-cc

cc_repos=$(aws codecommit list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$cc_repos" == "not empty" ]; then
  echo -e "${GREEN}Generating report for AWS CodeCommit repositories...${NC}"
  aws codecommit list-repositories | jq -r '["NAME", "ID"], (.repositories[] | [.repositoryName, .repositoryId]) | @csv' > aws-cc-"$REPORT_SUFFIX"
  generated+=("aws-cc-$REPORT_SUFFIX")
else
  echo -e "${RED}No repositories found in AWS CodeCommit.${NC}"
fi

# AWS CodeArtifact
# alias: aws-ca

ca_repos=$(aws codeartifact list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$ca_repos" == "not empty" ]; then
  echo -e "${GREEN}Generating report for AWS CodeArtifact repositories...${NC}"
  aws codeartifact list-repositories | jq -r '["NAME", "DOMAIN", "DESCRIPTION"], (.repositories[] | [.name, .domainName, .description]) | @csv' > aws-ca-"$REPORT_SUFFIX"
  generated+=("aws-ca-$REPORT_SUFFIX")
else
  echo -e "${RED}No repositories found in AWS CodeArtifact.${NC}"
fi

# AWS CodeBuild
# alias: aws-cb

cb_projects=$(aws codebuild list-projects | jq -r 'if (.projects | length > 0) then "not empty" else "empty" end')

if [ "$cb_projects" == "not empty" ]; then
  echo -e "${GREEN}Generating report for AWS CodeBuild projects...${NC}"
  aws codebuild list-projects | jq -r '["NAME"], (.projects[] | [.]) | @csv' > aws-cb-"$REPORT_SUFFIX"
  generated+=("aws-cb-$REPORT_SUFFIX")
else
  echo -e "${RED}No projects found in AWS CodeBuild.${NC}"
fi

# AWS CodeDeploy
# alias: aws-cd

cd_deployments=$(aws deploy list-applications | jq -r 'if (.applications | length > 0) then "not empty" else "empty" end')

if [ "$cd_deployments" == "not empty" ]; then
  echo -e "${GREEN}Generating report for AWS CodeDeploy applications...${NC}"
  aws deploy list-applications | jq -r '["NAME"], (.applications[] | [.]) | @csv' > aws-cd-"$REPORT_SUFFIX"
  generated+=("aws-cd-$REPORT_SUFFIX")
else
  echo -e "${RED}No applications found in AWS CodeDeploy.${NC}"
fi

# AWS CodePipeline
# alias: aws-cp

cp_pipelines=$(aws codepipeline list-pipelines | jq -r 'if (.pipelines | length > 0) then "not empty" else "empty" end')

if [ "$cp_pipelines" == "not empty" ]; then
  echo -e "${GREEN}Generating report for AWS CodePipeline pipelines...${NC}"
  aws codepipeline list-pipelines | jq -r '["NAME", "VERSION", "TYPE", "CREATED"], (.pipelines[] | [.name, .version, .pipelineType, .created]) | @csv' > aws-cp-"$REPORT_SUFFIX"
  generated+=("aws-cp-$REPORT_SUFFIX")
else
  echo -e "${RED}No pipelines found in AWS CodePipeline.${NC}"
fi

echo -e "${BLUE}====================================${NC}"
if [ ${#generated[@]} -gt 0 ]; then
  echo -e "${GREEN}Generated reports:${NC}"
  for report in "${generated[@]}"; do
    echo -e "  - $report"
  done
else
  echo -e "${RED}No reports generated.${NC}"
fi
echo -e "${BLUE}Report generation completed.${NC}"
