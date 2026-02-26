# Configure

List the profile, access key, secret key, and region for the specified user:
```shell
aws configure list
```

Import CSV credentials generated from the AWS web console:
```shell
aws configure import --csv file://<iam-user>_accessKeys.csv
```
