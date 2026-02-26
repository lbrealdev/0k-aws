# CodeDeploy

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
