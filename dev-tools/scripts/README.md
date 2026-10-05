# Scripts

Helpers for AWS developer tools services.

Convention: prefer **read-only** helpers for inventory/discovery. Write helpers should support `--dry-run` where practical and make side effects obvious.

| Script | Mode | Purpose |
|--------|------|---------|
| [`aws-dev-tools-report.sh`](./aws-dev-tools-report.sh) | Read-only | CSV reports for CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline; timestamped output directories |
| [`csv_to_xlsx.py`](./csv_to_xlsx.py) | Local | Convert generated CSVs into a single XLSX file with multiple worksheets |

Usage: `./aws-dev-tools-report.sh` and `uv run csv_to_xlsx.py <report_directory>`
