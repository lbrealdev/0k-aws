# Steampipe

## Installation

```shell
mise use -g steampipe
```

```shell
steampipe --version
```

## Usage

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

## Query examples

```shell
steampipe query "select name, arn, account_id, creation_date from aws_s3_bucket" --output table
```

### Connection configuration files

Steampipe config files use HCL syntax, with connections defined in a connection block.

Connection files are stored in the `~/.steampipe/config` directory.


- [AWS plugin on the Steampipe hub](https://hub.steampipe.io/plugins/turbot/aws)
- [steampipe-plugin-aws on GitHub](https://github.com/turbot/steampipe-plugin-aws)
- [Steampipe CLI plugin reference](https://steampipe.io/docs/reference/cli/plugin)
- [Steampipe CLI query reference](https://steampipe.io/docs/reference/cli/query)
- [AWS blog: simplify SQL queries to AWS API operations using Steampipe](https://aws.amazon.com/blogs/infrastructure-and-automation/simplify-sql-queries-to-aws-api-operations-using-steampipe-and-aws-plugin/)
- [steampipe-mod-aws-insights on GitHub](https://github.com/turbot/steampipe-mod-aws-insights)
