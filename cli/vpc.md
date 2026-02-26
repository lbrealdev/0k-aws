# VPC

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
