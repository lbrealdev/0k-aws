# 0k - AWS CLI Guide

<!-- TOC -->

- [Configure](#configure)
- [CodeArtifact](#codeartifact)
- [CodeDeploy](#codedeploy)
- [EC2](#ec2)
- [EC2 AMI](#ec2-ami)
- [EC2 Snapshots](s#ec2-snapshots)
- [Security Groups](#security-groups)
- [Secrets Manager](#secrets-manager)
- [VPC](#vpc)
- [EKS](#eks)
- [IAM](#iam)
- [S3](#S3)
- [STS](#STS)
- [SSO](#SSO)
- [Login](#login)
- [Logout](#logout)

### Configure

List the profile, access key, secret key, and region for the specified user:
```shell
aws configure list
```

Import CSV credentials generated from the AWS web console:
```shell
aws configure import --csv file://<iam-user>_accessKeys.csv
```

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

### S3

List s3 buckets:
```shell
aws s3 ls
```

List content in a specific s3 bucket:
```shell
aws s3 ls s3://<bucket-name>
```

Copy file from s3 bucket to local:
```shell
aws s3 cp s3://<bucket-name>/<file-name> <file-name>
```

Copy file from local to s3 bucket:
```shell
aws s3 cp <file-name> s3://<bucket-name>/<file-name>
```

Copy in recursive mode:
```shell
aws s3 cp . s3://<bucket-name> --recursive
```

### STS

Get details about the IAM user or role:
```shell
aws sts get-caller-identity
```

### SSO

```shell
aws sso-admin list-instances
```

### Login

```shell
aws login
```

### Logout

```shell
aws logout
```
