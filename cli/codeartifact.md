# CodeArtifact

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
