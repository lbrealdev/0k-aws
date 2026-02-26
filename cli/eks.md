# EKS

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
