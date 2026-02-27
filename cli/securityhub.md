# Security Hub

Get all findings:
```shell
aws securityhub get-findings \
  --output table
```

Get findings with specific severity:
```shell
aws securityhub get-findings \
  --filters '{"SeverityLabel": [{"Comparison": "EQUALS", "Value": "CRITICAL"}]}' \
  --output table
```

Get findings by compliance status:
```shell
aws securityhub get-findings \
  --filters '{"ComplianceStatus": [{"Comparison": "EQUALS", "Value": "FAILED"}]}' \
  --output table
```

Get findings by product name (e.g., Systems Manager):
```shell
aws securityhub get-findings \
  --filters '{"ProductName": [{"Comparison": "EQUALS", "Value": "Systems Manager"}]}' \
  --output table
```

Get SSM document findings:
```shell
aws securityhub get-findings \
  --filters '{
    "ProductName": [{"Comparison": "EQUALS", "Value": "Systems Manager"}],
    "ResourceType": [{"Comparison": "EQUALS", "Value": "AWS::SSM::Document"}]
  }' \
  --output table
```

Get SSM.4 findings (SSM documents should not be public):
```shell
aws securityhub get-findings \
  --filters '{
    "Title": [{"Comparison": "CONTAINS", "Value": "SSM documents should not be public"}],
    "ComplianceStatus": [{"Comparison": "EQUALS", "Value": "FAILED"}]
  }' \
  --output json
```

Get findings by resource region:
```shell
aws securityhub get-findings \
  --filters '{"Region": [{"Comparison": "EQUALS", "Value": "us-east-1"}]}' \
  --output table
```

Get findings by account ID:
```shell
aws securityhub get-findings \
  --filters '{"AwsAccountId": [{"Comparison": "EQUALS", "Value": "123456789012"}]}' \
  --output table
```

Get finding IDs only (useful for scripting):
```shell
aws securityhub get-findings \
  --filters '{"ComplianceStatus": [{"Comparison": "EQUALS", "Value": "FAILED"}]}' \
  --query 'Findings[].[Id]' \
  --output text
```

Get findings count by severity:
```shell
aws securityhub get-findings \
  --filters '{"ComplianceStatus": [{"Comparison": "EQUALS", "Value": "FAILED"}]}' \
  --query 'length(Findings)' \
  --output text
```

List enabled security standards:
```shell
aws securityhub get-enabled-standards \
  --output table
```

Get security hub member accounts:
```shell
aws securityhub list-members \
  --output table
```
