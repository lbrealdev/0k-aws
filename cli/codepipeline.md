# CodePipeline

```shell
aws codepipeline list-pipelines | jq -r '["NAME", "VERSION"], (.pipelines[] | [.name, .version] | @tsv' | column -t
```
