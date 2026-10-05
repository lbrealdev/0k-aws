# AWS Cloud Control API

List resources of a given type with Cloud Control:

```shell
aws cloudcontrol list-resources \
  --type-name AWS::S3::Bucket \
  --query "ResourceDescriptions[].Identifier" \
  --output table
```

Only resource types that support Cloud Control are listable this way; check the supported list below first.

## References

- [What is AWS Cloud Control API?](https://docs.aws.amazon.com/cloudcontrolapi/latest/userguide/what-is-cloudcontrolapi.html)
- [Resource types that support Cloud Control API](https://docs.aws.amazon.com/cloudcontrolapi/latest/userguide/supported-resources.html)
