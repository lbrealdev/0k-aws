# AWS Config

Inventory resources with AWS Config advanced queries.

List resources of a type with a SQL query (for multi-account results, run against an aggregator):

```shell
aws configservice select-resource-config \
  --expression "SELECT resourceId, awsRegion WHERE resourceType = 'AWS::EC2::Instance'" \
  --output table
```

Check whether a configuration recorder is active in the account/region:

```shell
aws configservice describe-configuration-recorders \
  --query "ConfigurationRecorders[].{Name:name,Role:roleARN,AllSupported:recordingGroup.allSupported}" \
  --output table
```

## References

- [What Is AWS Config?](https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html)
- [Query Using the SQL Query Editor for AWS Config (AWS CLI)](https://docs.aws.amazon.com/config/latest/developerguide/query-using-sql-editor-cli.html)
