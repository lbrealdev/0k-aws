# Security Groups

Count inbound rules from peer security groups:
```shell
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=<security-group-name>" \
  --query "SecurityGroups[*].{Name:GroupName,Ingress:IpPermissions[].UserIdGroupPairs.length(@)}" \
  --output json
```

Count inbound rules from IP ranges:
```shell
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=<security-group-name>" \
  --query "SecurityGroups[*].{Name:GroupName,Ingress: IpPermissions[].IpRanges.length(@)}" \
  --output json
```

List a specific security group:
```shell
aws ec2 describe-security-groups \
  --group-ids <security-group-id> \
  --query "SecurityGroups[*].{Name: GroupName, IngressRules: IpPermissions[].IpRanges, EgressRules: IpPermissionsEgress[]}" \
  --output json
```

## Related scripts

- [`scripts/sg-audit.sh`](../scripts/sg-audit.sh): read-only list of ingress rules open to `0.0.0.0/0` or `::/0`

