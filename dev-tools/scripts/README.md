# Scripts

Helpers for AWS developer tools services.

Convention: prefer **read-only** helpers for inventory/discovery. Write helpers should support `--dry-run` where practical and make side effects obvious.

| Script | Mode | Purpose |
|--------|------|---------|
| [`aws-devtools-report.sh`](../../scripts/aws-devtools-report.sh) | Read-only | CSV reports for CodeCommit, CodeArtifact, CodeBuild, CodeDeploy, CodePipeline; timestamped output directories |
| [`csv-to-xlsx.py`](../../scripts/csv-to-xlsx.py) | Local | Convert generated CSVs into a single XLSX file with multiple worksheets |

Usage: `./aws-devtools-report.sh` and `uv run csv-to-xlsx.py <report_directory>`
