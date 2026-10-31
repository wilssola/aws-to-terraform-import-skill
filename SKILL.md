---
name: aws-to-terraform-import
description: Import an existing AWS account into a new Terraform project with zero drift. Use when the user wants to codify, adopt, or "terraform import" infrastructure that was created by hand, console, or CloudFormation.
---

# AWS to Terraform import

Brings live AWS resources under Terraform **without changing anything in AWS**. Scripts live in `scripts/` next to this file (`<skill>/scripts`). They need `bash`, `aws` CLI v2, `terraform` >= 1.7 and `bun`.

The invariant for the whole flow: **never `apply` a plan that shows `to add`, `to change` or `to destroy`**. Only `N to import, 0 to add, 0 to change, 0 to destroy` may be applied.

## 1. Confirm the target before touching anything

Ask, do not assume:

- **AWS profile and account.** Run `aws sts get-caller-identity --profile <p>` and show the account ID to the user. Profiles in `~/.aws/config` often belong to *other* projects; never pick one by elimination.
- **Scope.** Is the whole account this project's, or is it shared? For shared accounts use `--filter <regex>` (matched on resource name and ID) and/or `--services`.
- **Regions.** Which regions hold resources? Cost Explorer grouped by region is the fastest answer. The first region in `--regions` is the provider region; others are imported with `@region` IDs (AWS provider >= 6).
- **State backend.** Local is fine to start; S3 with `use_lockfile` later.

If credentials are missing, the user has to log in themselves (`aws sso login --profile <p>`). For SSO "No AWS accounts are available to you" means an *account instance* of IAM Identity Center: it cannot grant account access. The fix is an organization instance (AWS Organizations → enable Identity Center → permission set → assign group to account).

## 2. Scaffold

Create `<tf-dir>/` with `templates/versions.tf`, `providers.tf`, `variables.tf` (set the profile default) and `templates/gitignore` as `.gitignore`. Run `terraform init`.

## 3. Discover → generate → fix → import

```bash
cd <tf-dir>
bash <skill>/scripts/discover.sh --profile <p> --regions <r1,r2>  # writes imports.tf (--list-services, --filter)
terraform plan -generate-config-out=generated.tf                   # expected to FAIL with config errors
bun <skill>/scripts/fix-generated.ts --profile <p>                 # patches known generator bugs
terraform fmt
terraform plan -out=.tmp/import.tfplan                             # gate: only "to import"
```

Resolve every remaining error or diff before continuing:

- **Error in generated HCL**: remove the conflicting attribute, or add a rule to `fix-generated.ts` so the fix is reproducible. Edit `generated.tf` by hand only for one-offs.
- **`will be updated in-place`**: read the diff. If it is a provider default with no real effect (`force_delete`, `publish`, `recovery_window_in_days`...), add it to `lifecycle.ignore_changes`. If it is a real value, the HCL is wrong: fix it.
- **Deploy-owned fields** (ECS `task_definition`/`desired_count`, weighted listener rules) change on every deploy done outside Terraform. Ask the user who owns deploys; if it is not Terraform, re-run `fix-generated.ts --ignore-deploy-drift`.
- **Resource you do not want** (another team's, an experiment): delete its `import {}` block and its generated `resource` block, then re-plan.
- **`connectex ... forbidden by its access permissions`** (Windows): local network flake. Retry.

Then:

```bash
terraform apply .tmp/import.tfplan                 # writes state only
bun <skill>/scripts/fix-generated.ts --post-import && terraform fmt
terraform plan -detailed-exitcode                  # gate: exit 0, "No changes"
```

## 4. Audit coverage

`discover.sh` only knows a fixed list of services. Always check what it missed:

```bash
bun <skill>/scripts/audit-coverage.ts --profile <p> --region <aggregator-region>
```

It needs an AWS Resource Explorer **aggregator** index. If none exists, fall back to Cost Explorer by service/region to find spend that is not in state. Classic misses: the **default VPC** (many apps run in it), RDS Proxy, WAF, EFS, dashboards, Cognito, Lambda permissions.

Show the user the gaps grouped as: belongs to the project / probably someone else's or an experiment / AWS-managed noise. Let the user decide; do not infer ownership from names alone. For each gap they accept, add a section to `discover.sh` (or a manual `import {}` block), regenerate into a **new** file (`-generate-config-out=generated2.tf`; Terraform only generates for addresses not yet in config), and repeat step 3.

## 5. Organize

```bash
bun <skill>/scripts/split-by-service.ts && terraform fmt       # generated*.tf -> rds.tf, ecs.tf, ...
bun <skill>/scripts/link-references.ts && terraform fmt        # "vpc-123" -> aws_vpc.x.id
terraform validate && terraform plan -detailed-exitcode        # gate: still "No changes"
```

Both scripts only rewrite text; resource addresses are unchanged, so state is unaffected. Unknown types land in `misc.tf`: add their prefix to `split-by-service.ts`.

## 6. Hand over

Before committing, scan for plaintext secrets (ECS `environment`, Lambda env vars, user data). `*.tfstate` must stay out of git. Commit the `.tf` files, `imports.tf`, `lambda/*.zip`, `.terraform.lock.hcl`.

Tell the user:

- Resources owned by CloudFormation stacks (`aws cloudformation list-stacks`) are now co-managed: change them in one place only.
- `aws_default_*` resources are never deleted by `destroy`, only dropped from state.
- Local state is a single point of failure until moved to S3.

## Gotchas the scripts already handle

Know these when a new error looks similar:

| Resource | Problem | Fix |
| --- | --- | --- |
| `aws_default_route_table` | Import ID is the **VPC ID**, not the `rtb-` ID | `discover.sh` |
| `aws_route_table` / default | `""` in route fields fails CIDR validation | `""` → `null` |
| `aws_subnet` / default | `availability_zone` vs `_id`, `enable_lni_at_device_index = 0`, customer-owned IP trio | drop attributes |
| `aws_instance` | `primary_network_interface` vs `associate_public_ip_address`; `ipv6_addresses` vs `_count` | drop block/attr |
| `aws_lb` | `subnets` and `subnet_mapping` both set | drop `subnet_mapping` |
| `aws_lb_listener[_rule]` | `target_group_arn` plus `forward {}` → perpetual diff | `--post-import` |
| `aws_lb_target_group` | `target_control_port = 0`, empty `target_failover` | drop |
| `aws_key_pair` | `public_key` not importable | fetch from EC2 + ignore |
| `aws_lambda_function` | Zip code not importable | download to `lambda/<fn>.zip` |
| `aws_cognito_user_pool_client` | token validity `0` | drop |
| CloudFront functions | duplicated per stage (DEVELOPMENT/LIVE) | `sort -u` |
| `aws_secretsmanager_secret` | `rds!` secrets are RDS-managed | skipped |
| CloudWatch alarms | `TargetTracking-*` are Auto Scaling-managed | skipped |
