# Steampipe

### Usage

```shell
steampipe plugin list
```

```shell
steampipe plugin install aws
```

```shell
steampipe plugin uninstall aws
```

```shell
steampipe plugin update aws
```

### Queries Examples

```shell
steampipe query "select name, arn, account_id, creation_date from aws_s3_bucket" --output table
```

### Connection configuration files

Steampipe config files use HCL Syntax, with connections defined in a connection block.

Connections files are stored in `~/.steampipe/config` directory.


- https://hub.steampipe.io/plugins/turbot/aws
- https://github.com/turbot/steampipe-plugin-aws
- https://steampipe.io/docs/reference/cli/plugin
- https://steampipe.io/docs/reference/cli/query
- https://aws.amazon.com/blogs/infrastructure-and-automation/simplify-sql-queries-to-aws-api-operations-using-steampipe-and-aws-plugin/
- https://github.com/turbot/steampipe-mod-aws-insights
