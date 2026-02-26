# Secrets Manager

Get secret value:
```shell
aws secretsmanager get-secret-value --secret-id "<secret-name>" --query "SecretString" --output text | jq .
```
