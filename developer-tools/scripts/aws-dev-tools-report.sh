#!/bin/bash

set -euo pipefail

AWS_ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
TIMESTAMP=$(date '+%Y%d%m%H%M%S')
REPORT_SUFFIX="${AWS_ACCOUNT}_${TIMESTAMP}.csv"

# AWS CodeCommit
# alias: aws-cc

cc_repos=$(aws codecommit list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$cc_repos" == "not empty" ]; then
  echo "Generating AWS CodeCommit report..."
  aws codecommit list-repositories | jq -r '["NAME", "ID"], (.repositories[] | [.repositoryName, .repositoryId]) | @csv' > aws-cc-"$REPORT_SUFFIX"
else
  echo "No repositories found in AWS CodeCommit."
fi

# AWS CodeArtifact
# alias: aws-ca

ca_repos=$(aws codeartifact list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')

if [ "$ca_repos" == "not empty" ]; then
  echo "Generating AWS CodeArtifact report..."
  aws codeartifact list-repositories | jq -r '["NAME", "DOMAIN", "DESCRIPTION"], (.repositories[] | [.name, .domainName, .description]) | @csv' > aws-ca-"$REPORT_SUFFIX"
else
  echo "No repositories found in AWS CodeArtifact."
fi

# AWS CodeBuild
# alias: aws-cb

cb_projects=$(aws codebuild list-projects | jq -r 'if (.projects | length > 0) then "not empty" else "empty" end')

if [ "$cb_projects" == "not empty" ]; then
  echo "Generating AWS CodeBuild report..."
  aws codebuild list-projects | jq -r '["NAME"], (.projects[] | [.]) | @csv' > aws-cb-"$REPORT_SUFFIX"
else
  echo "No projects found in AWS CodeBuild."
fi

# AWS CodeDeploy
# alias: aws-cd

cd_deployments=$(aws deploy list-applications | jq -r 'if (.applications | length > 0) then "not empty" else "empty" end')

if [ "$cd_deployments" == "not empty" ]; then
  echo "Generating AWS CodeDeploy report..."
  aws deploy list-applications | jq -r '["NAME"], (.applications[] | [.]) | @csv' > aws-cd-"$REPORT_SUFFIX"
else
  echo "No applications found in AWS CodeDeploy."
fi

# AWS CodePipeline
# alias: aws-cp

cp_pipelines=$(aws codepipeline list-pipelines | jq -r 'if (.pipelines | length > 0) then "not empty" else "empty" end')

if [ "$cp_pipelines" == "not empty" ]; then
  echo "Generating AWS CodePipeline report..."
  aws codepipeline list-pipelines | jq -r '["NAME", "VERSION", "TYPE", "CREATED"], (.pipelines[] | [.name, .version, .pipelineType, .created]) | @csv' > aws-cp-"$REPORT_SUFFIX"
else
  echo "No pipelines found in AWS CodePipeline."
fi
