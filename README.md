# aws-to-terraform-import-skill

An agent skill that imports an existing AWS account into a new Terraform project with **zero drift**, using `import {}` blocks and `terraform plan -generate-config-out`.

Works for any account: pick regions and services, or filter a shared account down to one project. Every `-generate-config-out` bug found in real imports is a rule in `scripts/fix-generated.ts`, so a fresh run reaches a clean plan without hand edits.

## Install

Copy or symlink this folder into your agent's skills directory (for example `~/.agents/skills/aws-to-terraform-import`). The agent reads `SKILL.md`.

Requirements: `bash` (Git Bash on Windows), AWS CLI v2, Terraform >= 1.7, [Bun](https://bun.sh).

## Scripts

| Script | What it does |
| --- | --- |
| `discover.sh` | Lists resources with the AWS CLI and writes `imports.tf` (`--regions`, `--services`, `--filter`) |
| `fix-generated.ts` | Patches known errors in generated HCL (`--post-import`, `--ignore-deploy-drift`) |
| `audit-coverage.ts` | Diffs Resource Explorer inventory against state |
| `split-by-service.ts` | Moves `generated*.tf` into `rds.tf`, `ecs.tf`, ... |
| `link-references.ts` | Rewrites hardcoded IDs/ARNs into resource references |

All scripts accept `--dir <tf-dir>` (default: current directory) and `--profile` (env fallbacks: `TF_DIR`, `AWS_PROFILE_TF`). Region defaults to the profile's configured region.

## Workflow

```bash
bash scripts/discover.sh --profile my-profile --regions us-east-1,eu-west-1
terraform plan -generate-config-out=generated.tf
bun scripts/fix-generated.ts --profile my-profile && terraform fmt
terraform plan -out=.tmp/import.tfplan          # must be imports only
terraform apply .tmp/import.tfplan
bun scripts/fix-generated.ts --post-import && terraform fmt
bun scripts/audit-coverage.ts --profile my-profile
bun scripts/split-by-service.ts && bun scripts/link-references.ts && terraform fmt
terraform plan -detailed-exitcode               # must be "No changes"
```

See [`SKILL.md`](SKILL.md) for the gates and decisions between steps.

## Coverage

Run `bash scripts/discover.sh --list-services`. Today: S3, SQS, SNS, IAM, KMS, Secrets Manager, SSM, VPC (including the default VPC), EC2, Auto Scaling, ELBv2, ECR, ECS, Application Auto Scaling, RDS, RDS Proxy, ElastiCache, DynamoDB, Lambda, EventBridge, API Gateway, CloudWatch, SES, EFS, Cognito, ACM, WAFv2, EKS, Step Functions, Kinesis/Firehose, CloudTrail, AWS Backup, OpenSearch, CodeBuild/CodePipeline, CloudFront, Route53.

Regions other than the first are imported with `@region` IDs, which needs AWS provider >= 6.

Anything else: run `audit-coverage.ts`, then add a section to `discover.sh`.
