# Security Groups

List security groups by filtering by security group name with query for IpPermissions `(Inbound Rules)` of just UserIdGroupPairs `(security group IDs)` counting their length and json output format:
````shell
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=<security-group-name>" \
  --query "SecurityGroups[*].{Name:GroupName,Ingress:IpPermissions[].UserIdGroupPairs.length(@)}" \
  --output json
````

List security groups by filtering by name with query for IpPermissions `(Inbound Rules)` of just IpRanges `(IPs/CIDRs)` counting their length and json output format:
````shell
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=<security-group-name>" \
  --query "SecurityGroups[*].{Name:GroupName,Ingress: IpPermissions[].IpRanges.length(@)}" \
  --output json
````

List a specific security group:
```shell
aws ec2 describe-security-groups \
  --group-ids <security-group-id> \
  --query "SecurityGroups[*].{Name: GroupName, IngressRules: IpPermissions[].IpRanges, EgressRules: IpPermissionsEgress[]}" \
  --output json
```
