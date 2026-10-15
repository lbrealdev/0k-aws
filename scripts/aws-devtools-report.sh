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

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate CSV reports for AWS developer tools (CodeCommit, CodeArtifact,
CodeBuild, CodeDeploy, CodePipeline) in the current account.

Options:
  --xlsx             Convert CSV reports to a single XLSX (requires uv)
  -q, --quiet        Suppress the header and non-error status rows
  -h, --help         Show this help message

Examples:
  $0
  $0 --xlsx
EOF
}

error() { ui_always "$(ui_color red)[ERROR]$(ui_color reset) $*"; }
warn()  { ui_always "$(ui_color yellow)[WARN]$(ui_color reset)  $*"; }
info()  { ui_row "$(ui_color blue)[INFO]$(ui_color reset)  $*"; }

XLSX_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --xlsx)
            XLSX_MODE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -q|--quiet)
            ui_quiet
            shift
            ;;
        *)
            error "unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

# Array to track generated reports
generated=()

TIMESTAMP=$(date '+%Y%m%d%H%M%S')
REPORT_DIR="aws_report_$(date '+%Y%m%d')"

ui_header "aws-dev-tools-report: CSV reports for AWS developer tools"

# Check AWS credentials and retrieve account
if ACCOUNT=$(aws sts get-caller-identity 2>/dev/null | jq -r '.Account' 2>/dev/null); then
  AWS_ACCOUNT="$ACCOUNT"
  REPORT_SUFFIX="${AWS_ACCOUNT}_${TIMESTAMP}.csv"
  mkdir -p "$REPORT_DIR"
else
  error "Invalid or missing AWS credentials/access keys."
  exit 1
fi

# AWS CodeCommit
# alias: aws-cc

if aws codecommit list-repositories > /dev/null 2>&1; then
  has_codecommit_repos=$(aws codecommit list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')
else
  warn "Insufficient permissions to access CodeCommit. Skipping report."
  has_codecommit_repos="access_denied"
fi

if [ "$has_codecommit_repos" == "not empty" ]; then
  info "Generating report for AWS CodeCommit..."
  aws codecommit list-repositories | jq -r '["NAME", "ID"], (.repositories[] | [.repositoryName, .repositoryId]) | @csv' > "$REPORT_DIR/aws-cc-$REPORT_SUFFIX"
  generated+=("aws-cc-$REPORT_SUFFIX")
elif [ "$has_codecommit_repos" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  info "No repositories found in AWS CodeCommit."
fi

# AWS CodeArtifact
# alias: aws-ca

if aws codeartifact list-repositories > /dev/null 2>&1; then
  has_codeartifact_repos=$(aws codeartifact list-repositories | jq -r 'if (.repositories | length > 0) then "not empty" else "empty" end')
else
  warn "Insufficient permissions to access CodeArtifact. Skipping report."
  has_codeartifact_repos="access_denied"
fi

if [ "$has_codeartifact_repos" == "not empty" ]; then
  info "Generating report for AWS CodeArtifact..."
  aws codeartifact list-repositories | jq -r '["NAME", "DOMAIN", "DESCRIPTION"], (.repositories[] | [.name, .domainName, .description]) | @csv' > "$REPORT_DIR/aws-ca-$REPORT_SUFFIX"
  generated+=("aws-ca-$REPORT_SUFFIX")
elif [ "$has_codeartifact_repos" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  info "No repositories found in AWS CodeArtifact."
fi

# AWS CodeBuild
# alias: aws-cb

if aws codebuild list-projects > /dev/null 2>&1; then
  has_codebuild_projects=$(aws codebuild list-projects | jq -r 'if (.projects | length > 0) then "not empty" else "empty" end')
else
  warn "Insufficient permissions to access CodeBuild. Skipping report."
  has_codebuild_projects="access_denied"
fi

if [ "$has_codebuild_projects" == "not empty" ]; then
  info "Generating report for AWS CodeBuild..."
  aws codebuild list-projects | jq -r '["NAME"], (.projects[] | [.]) | @csv' > "$REPORT_DIR/aws-cb-$REPORT_SUFFIX"
  generated+=("aws-cb-$REPORT_SUFFIX")
elif [ "$has_codebuild_projects" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  info "No projects found in AWS CodeBuild."
fi

# AWS CodeDeploy
# alias: aws-cd

if aws deploy list-applications > /dev/null 2>&1; then
  has_codedeploy_applications=$(aws deploy list-applications | jq -r 'if (.applications | length > 0) then "not empty" else "empty" end')
else
  warn "Insufficient permissions to access CodeDeploy. Skipping report."
  has_codedeploy_applications="access_denied"
fi

if [ "$has_codedeploy_applications" == "not empty" ]; then
  info "Generating report for AWS CodeDeploy..."
  aws deploy list-applications | jq -r '["NAME"], (.applications[] | [.]) | @csv' > "$REPORT_DIR/aws-cd-$REPORT_SUFFIX"
  generated+=("aws-cd-$REPORT_SUFFIX")
elif [ "$has_codedeploy_applications" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  info "No applications found in AWS CodeDeploy."
fi

# AWS CodePipeline
# alias: aws-cp

if aws codepipeline list-pipelines > /dev/null 2>&1; then
  has_codepipeline_pipelines=$(aws codepipeline list-pipelines | jq -r 'if (.pipelines | length > 0) then "not empty" else "empty" end')
else
  warn "Insufficient permissions to access CodePipeline. Skipping report."
  has_codepipeline_pipelines="access_denied"
fi

if [ "$has_codepipeline_pipelines" == "not empty" ]; then
  info "Generating report for AWS CodePipeline..."
  aws codepipeline list-pipelines | jq -r '["NAME", "VERSION", "TYPE", "CREATED"], (.pipelines[] | [.name, .version, .pipelineType, .created]) | @csv' > "$REPORT_DIR/aws-cp-$REPORT_SUFFIX"
  generated+=("aws-cp-$REPORT_SUFFIX")
elif [ "$has_codepipeline_pipelines" == "access_denied" ]; then
  # Report skipped due to permissions
  :
else
  info "No pipelines found in AWS CodePipeline."
fi

# Check if any reports were generated
HAS_REPORTS=false
if [ ${#generated[@]} -gt 0 ]; then
    HAS_REPORTS=true
fi

if [ "$HAS_REPORTS" = true ]; then
    if [ "$XLSX_MODE" = true ]; then
        if command -v uv > /dev/null 2>&1; then
            info "Generating XLSX report..."
            uv run csv-to-xlsx.py "$REPORT_DIR" || { error "XLSX creation failed. CSV files preserved."; exit 1; }
            info "XLSX created successfully. Cleaning up CSV files..."
            rm -f "$REPORT_DIR"/*.csv
            info "Final report: $REPORT_DIR/final_report.xlsx"
        else
            error "UV not installed. Install UV to use --xlsx mode."
            exit 1
        fi
    else
        info "Generated reports in directory: $REPORT_DIR"
        for report in "${generated[@]}"; do
            info "  - $REPORT_DIR/$report"
        done
    fi
else
    info "No reports were generated."
    if [ "$XLSX_MODE" = true ]; then
        info "Skipping XLSX."
        exit 1
    fi
fi

info "Process completed."
