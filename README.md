# 0k - AWS CLI Guide

<!-- TOC -->

- [CodeArtifact](https://github.com/lbrealdev/0k-aws#codeartifact)
- [CodeDeploy](https://github.com/lbrealdev/0k-aws#codedeploy)
- [EC2](https://github.com/lbrealdev/0k-aws#ec2)
- [EC2 AMI](https://github.com/lbrealdev/0k-aws#ec2-ami)
- [EC2 Snapshots](https://github.com/lbrealdev/0k-aws#ec2-snapshots)
- [Security Groups](https://github.com/lbrealdev/0k-aws#security-groups)
- [Secrets Manager](https://github.com/lbrealdev/0k-aws#secrets-manager)
- [VPC](https://github.com/lbrealdev/0k-aws#vpc)
- [EKS](https://github.com/lbrealdev/0k-aws#eks)
- [IAM](https://github.com/lbrealdev/0k-aws#iam)

### CodeArtifact

Get a temporary authorization token to access CodeArtifact repositories by passing a query by `authorizationToken` with a text output:
```shell
aws codeartifact get-authorization-token --domain <domain>  --domain-owner <owner-account> --duration-seconds 20000 --query "authorizationToken" --output text
```

Describe CodeArtifact domain:
```shell
aws codeartifact describe-domain --domain <domain>
```

Describe CodeArtifact repository:
```shell
aws codeartifact describe-repository --domain <domain> --repository <repository-name>
```

Get CodeArtifact repository endpoint:
```shell
aws codeartifact get-repository-endpoint --domain <domain> --repository <repository-name> --format <format>
```

Add repository upstream in CodeArtifact repository:
```shell
aws codeartifact update-repository \
  --domain <domain> \
  --domain-owner <owner-account> \
  --repository <repository-name> \
  --upstreams repositoryName=<upstream-repository-name>
```

List packages in the repository:
```shell
aws codeartifact list-packages --domain <domain> --repository <repository-name>
```

#### Sources

- [Upstream repository priority order](https://docs.aws.amazon.com/codeartifact/latest/ug/repo-upstream-search-order.html)

### CodeDeploy

Get CodeDeploy application:
```shell
aws deploy get-application --application-name <application-name>
```

List CodeDeploy application deployments:
```shell
aws deploy list-deployments \
  --application-name <application-name> \
  --create-time-range start=2024-12-01T00:00:00,end=2024-12-17T00:00:00 \
  --deployment-group-name <deployment-group-name> \
  --include-only-statuses Succeeded
```

Get CodeDeploy deployment:
```shell
aws deploy get-deployment --deployment-id <deployment-id>
```

### EC2

List EC2 instances by filtering by tag:name value with queries to display some reverse sort data fields for runtime with table output format:
```shell
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=<instance-name>" \
  --filters "Name=instance-state-name,Values=<instance-state>" \
  --query "reverse(sort_by(Reservations[*].Instances[].{ID:InstanceId,Type:InstanceType,Status:State.Name,Init:LaunchTime,EC2Name:Tags[?Key == 'Name'].Value | [0]} &Init))" \
  --output table
```

### EC2 AMI

List all AMIs filtering by name by sorting the query by creation date of all images:
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query 'reverse(sort_by(Images[*], &CreationDate)[].Name)' \
  --output table
```

Get the latest AMI ID:
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query 'sort_by(Images[*], &CreationDate)[-1].[ImageId]' \
  --output table
```

List all AMIs by filtering by name, passing query in table format output with some AMI properties.
```shell
aws ec2 describe-images \
  --filters "Name=name,Values=<ami-name-*>" \
  --query "sort_by(Images[*].{AMI:Name,ID:ImageId,Owner:OwnerId,Date:CreationDate,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}, &Date)" \
  --output table
```

### EC2 Snapshots

List all snapshots filtering by owner id and snapshot status passing query by snapshot id and tag key:
```shell
aws ec2 describe-snapshots \
  --filters "Name=status,Values=completed" \
  --filters "Name=owner-id,Values=<owner-id>" \
  --query "Snapshots[*].{ID:SnapshotId,Name:Tags[?Key == 'Name'].Value | [0]}" \
  --output table
```

### Security Groups

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

### Secrets Manager

Get secret value:
```shell
aws secretsmanager get-secret-value --secret-id "<secret-name>" --query "SecretString" --output text | jq .
```

### VPC

List all subnets in table format:
```shell
aws ec2 describe-subnets \
 --query "sort_by(Subnets[].{Name:Tags[?Key == 'Name'].Value | [0],Vpc:VpcId,Id:SubnetId,AvailableIps:AvailableIpAddressCount} &Name)" \
 --output table
```

List all VPCs in table format:
```shell
aws ec2 describe-vpcs \
  --query "Vpcs[].{Name:Tags[?Key == 'Name'].Value | [0],VpcId:VpcId,CIDR:CidrBlock,Account:OwnerId}" \
  --output table
```

### EKS

List all EKS clusters in yaml format:
```shell
aws eks list-clusters --output yaml
```

List the access entries for EKS cluster:
```shell
aws eks list-access-entries --cluster-name "<eks-cluster-name>" --output yaml
```

Configures kubeconfig to connect to the EKS cluster:
```shell
aws eks update-kubeconfig --name "<eks-cluster-name>" --region "<aws-region>" 
```

### IAM

Get IAM role:
```shell
aws iam get-role --role-name <iam-role-name>
```

### OpenSearch

List domain names:
```shell
aws opensearch list-domain-names --engine-type OpenSearch
```
