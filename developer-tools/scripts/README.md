# Scripts Directory

This directory contains utility scripts for AWS developer tools.

## aws-dev-tools-report.sh
Bash script to generate CSV reports for AWS services (CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline). Checks permissions, organizes outputs in timestamped directories, and handles errors gracefully.

Usage: `./aws-dev-tools-report.sh`

## csv_to_xlsx.py
Python script to convert generated CSV files into a single XLSX file with multiple worksheets.

Usage: `uv run csv_to_xlsx.py <report_directory>`