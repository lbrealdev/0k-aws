# IAM

Get IAM role:
```shell
aws iam get-role --role-name <iam-role-name>
```

Attach or detach a tagged customer managed policy. `--dry-run` prints the plan and writes nothing:

```shell
scripts/aws-iam-policy-role.sh attach --profile <profile> --role-name <role> \
    --policy-name <name> --tag <key=value> --policy-file <policy.json> --dry-run
scripts/aws-iam-policy-role.sh detach --profile <profile> --role-name <role> \
    --policy-name <name> --tag <key=value> --dry-run
```
