#!/usr/bin/env bash
# Discovers existing AWS resources and writes Terraform `import {}` blocks to imports.tf.
#
# Usage: discover.sh --profile <p> [--regions r1,r2] [--services s1,s2] [--filter <regex>] [--dir <tf-dir>]
#   --regions   Comma-separated. The first is the provider region; others get `@region` import IDs
#               (AWS provider >= 6). Default: the profile's configured region.
#   --services  Comma-separated subset (default: all). See --list-services.
#   --filter    Extended regex matched against resource name and ID; non-matching resources are skipped.
#               For shared accounts. Not applied to the `vpc` service (network names are generic).
# Env fallbacks: AWS_PROFILE_TF, AWS_REGIONS_TF, TF_DIR.
set -uo pipefail

PROFILE="${AWS_PROFILE_TF:-${AWS_PROFILE:-default}}"
REGIONS="${AWS_REGIONS_TF:-}"
SERVICES=""
FILTER=""
ROOT="${TF_DIR:-$PWD}"

REGIONAL_SERVICES="s3 sqs sns kms secretsmanager ssm vpc ec2 elbv2 ecr ecs appautoscaling rds rdsproxy elasticache dynamodb lambda lambdaperm events apigateway cloudwatch ses efs cognito acm wafv2 eks sfn kinesis cloudtrail backup opensearch codebuild"
GLOBAL_SERVICES="iam cloudfront route53 wafv2cf"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--profile) PROFILE="$2"; shift 2 ;;
	--region | --regions) REGIONS="$2"; shift 2 ;;
	--services) SERVICES="$2"; shift 2 ;;
	--filter) FILTER="$2"; shift 2 ;;
	--dir) ROOT="$2"; shift 2 ;;
	--list-services) echo "regional: $REGIONAL_SERVICES"; echo "global:   $GLOBAL_SERVICES"; exit 0 ;;
	-h | --help) sed -n '2,10p' "$0"; exit 0 ;;
	*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
done
ROOT="$(cd "$ROOT" && pwd)"
OUT="$ROOT/imports.tf"

aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1 || {
	echo "Invalid credentials. Run: aws sso login --profile $PROFILE" >&2
	exit 1
}
[[ -z "$REGIONS" ]] && REGIONS="$(aws configure get region --profile "$PROFILE" 2>/dev/null | tr -d '\r')"
[[ -z "$REGIONS" ]] && { echo "No region configured: pass --regions" >&2; exit 2; }
IFS=',' read -r -a REGION_LIST <<<"$REGIONS"
PRIMARY="${REGION_LIST[0]}"
REGION="$PRIMARY"
SCOPE=global
CURRENT=""

declare -A SEEN
COUNT=0
SKIPPED=0

aws_cmd() { aws --profile "$PROFILE" --region "$REGION" --output text "$@" 2>/dev/null | tr -d '\r'; }
# Single column -> one item per line
list() { aws_cmd "$@" | tr '\t' '\n' | grep -v -E '^(None)?$'; }
# Multiple columns -> tab-separated rows
rows() { aws_cmd "$@" | grep -v -E '^(None)?$'; }

emit() {
	local type="$1" name="$2" id="$3" n key i=2
	if [[ -n "$FILTER" && "$CURRENT" != vpc ]] && ! printf '%s %s' "$name" "$id" | grep -qiE "$FILTER"; then
		SKIPPED=$((SKIPPED + 1))
		return
	fi
	# Regional resources outside the provider region need an `@region` import ID suffix
	if [[ "$SCOPE" == regional && "$REGION" != "$PRIMARY" ]]; then
		id="$id@$REGION"
		name="${name}_$REGION"
	fi
	n=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+//; s/_+$//; s/^([0-9])/r_\1/')
	[[ -z "$n" ]] && n="res"
	key="$type.$n"
	while [[ -n "${SEEN[$key]:-}" ]]; do key="$type.${n}_$i"; i=$((i + 1)); done
	SEEN[$key]=1
	COUNT=$((COUNT + 1))
	printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$key" "$id" >>"$OUT"
}

wanted() { [[ -z "$SERVICES" || ",$SERVICES," == *",$1,"* ]]; }

run() {
	CURRENT="$1"
	printf '\n# --- %s (%s) ---\n\n' "$(label "$1")" "$REGION" >>"$OUT"
	echo ">> $(label "$1") [$REGION]"
	"svc_$1"
}

label() {
	case "$1" in
	s3) echo "S3" ;;
	sqs) echo "SQS" ;;
	sns) echo "SNS" ;;
	kms) echo "KMS" ;;
	secretsmanager) echo "Secrets Manager" ;;
	ssm) echo "SSM Parameters" ;;
	vpc) echo "VPC" ;;
	ec2) echo "EC2" ;;
	elbv2) echo "ELBv2" ;;
	ecr) echo "ECR" ;;
	ecs) echo "ECS" ;;
	appautoscaling) echo "Application Auto Scaling" ;;
	rds) echo "RDS" ;;
	rdsproxy) echo "RDS Proxy" ;;
	elasticache) echo "ElastiCache" ;;
	dynamodb) echo "DynamoDB" ;;
	lambda) echo "Lambda" ;;
	lambdaperm) echo "Lambda permissions" ;;
	events) echo "EventBridge" ;;
	apigateway) echo "API Gateway" ;;
	cloudwatch) echo "CloudWatch" ;;
	ses) echo "SES" ;;
	efs) echo "EFS" ;;
	cognito) echo "Cognito" ;;
	acm) echo "ACM" ;;
	wafv2) echo "WAFv2" ;;
	eks) echo "EKS" ;;
	sfn) echo "Step Functions" ;;
	kinesis) echo "Kinesis / Firehose" ;;
	cloudtrail) echo "CloudTrail" ;;
	backup) echo "AWS Backup" ;;
	opensearch) echo "OpenSearch" ;;
	codebuild) echo "CodeBuild / CodePipeline" ;;
	iam) echo "IAM" ;;
	cloudfront) echo "CloudFront" ;;
	route53) echo "Route53" ;;
	wafv2cf) echo "WAFv2 (CloudFront scope)" ;;
	*) echo "$1" ;;
	esac
}

# ---------- Services ----------

svc_s3() {
	for b in $(list s3api list-buckets --query 'Buckets[].Name'); do
		loc=$(aws_cmd s3api get-bucket-location --bucket "$b" --query LocationConstraint)
		[[ "$loc" == "None" || -z "$loc" ]] && loc="us-east-1"
		[[ "$loc" == "EU" ]] && loc="eu-west-1"
		[[ "$loc" != "$REGION" ]] && continue
		emit aws_s3_bucket "$b" "$b"
		emit aws_s3_bucket_server_side_encryption_configuration "$b" "$b"
		aws_cmd s3api get-public-access-block --bucket "$b" >/dev/null && emit aws_s3_bucket_public_access_block "$b" "$b"
		[[ -n "$(aws_cmd s3api get-bucket-versioning --bucket "$b" --query Status | grep -v None)" ]] && emit aws_s3_bucket_versioning "$b" "$b"
		aws_cmd s3api get-bucket-policy --bucket "$b" >/dev/null && emit aws_s3_bucket_policy "$b" "$b"
		aws_cmd s3api get-bucket-cors --bucket "$b" >/dev/null && emit aws_s3_bucket_cors_configuration "$b" "$b"
		aws_cmd s3api get-bucket-lifecycle-configuration --bucket "$b" >/dev/null && emit aws_s3_bucket_lifecycle_configuration "$b" "$b"
		aws_cmd s3api get-bucket-ownership-controls --bucket "$b" >/dev/null && emit aws_s3_bucket_ownership_controls "$b" "$b"
		aws_cmd s3api get-bucket-notification-configuration --bucket "$b" | grep -q . && emit aws_s3_bucket_notification "$b" "$b"
	done
}

svc_sqs() {
	for u in $(list sqs list-queues --query 'QueueUrls[]'); do emit aws_sqs_queue "${u##*/}" "$u"; done
}

svc_sns() {
	for a in $(list sns list-topics --query 'Topics[].TopicArn'); do emit aws_sns_topic "${a##*:}" "$a"; done
	while IFS=$'\t' read -r arn topic; do
		[[ "$arn" == PendingConfirmation || "$arn" == Deleted ]] && continue
		emit aws_sns_topic_subscription "${topic##*:}_sub" "$arn"
	done < <(rows sns list-subscriptions --query 'Subscriptions[].[SubscriptionArn,TopicArn]')
}

svc_kms() {
	while IFS=$'\t' read -r alias key; do
		[[ "$alias" == alias/aws/* || -z "$key" || "$key" == None ]] && continue
		emit aws_kms_key "${alias#alias/}" "$key"
		emit aws_kms_alias "${alias#alias/}" "$alias"
	done < <(rows kms list-aliases --query 'Aliases[].[AliasName,TargetKeyId]')
}

svc_secretsmanager() {
	while IFS=$'\t' read -r arn name; do emit aws_secretsmanager_secret "$name" "$arn"; done \
		< <(rows secretsmanager list-secrets --query 'SecretList[?!OwningService].[ARN,Name]')
}

svc_ssm() {
	for p in $(list ssm describe-parameters --query 'Parameters[].Name'); do emit aws_ssm_parameter "$p" "$p"; done
}

svc_vpc() {
	for v in $(list ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId'); do emit aws_vpc "$v" "$v"; done
	for s in $(list ec2 describe-subnets --query 'Subnets[?DefaultForAz==`false`].SubnetId'); do emit aws_subnet "$s" "$s"; done

	# Default VPC: aws_default_* resources (destroy only removes them from state)
	for v in $(list ec2 describe-vpcs --query 'Vpcs[?IsDefault==`true`].VpcId'); do
		emit aws_default_vpc "$v" "$v"
		# Import ID is the VPC ID (provider filters association.main + vpc-id)
		rt=$(list ec2 describe-route-tables --filters Name=vpc-id,Values="$v" Name=association.main,Values=true --query 'RouteTables[0].RouteTableId')
		[[ -n "$rt" ]] && emit aws_default_route_table "$rt" "$v"
		dhcp=$(list ec2 describe-vpcs --vpc-ids "$v" --query 'Vpcs[0].DhcpOptionsId')
		[[ -n "$dhcp" && "$dhcp" != default ]] && emit aws_default_vpc_dhcp_options "$dhcp" "$dhcp"
		for a in $(list ec2 describe-network-acls --filters Name=vpc-id,Values="$v" Name=default,Values=true --query 'NetworkAcls[].NetworkAclId'); do
			emit aws_default_network_acl "$a" "$a"
		done
		for g in $(list ec2 describe-security-groups --filters Name=vpc-id,Values="$v" Name=group-name,Values=default --query 'SecurityGroups[].GroupId'); do
			emit aws_default_security_group "$g" "$g"
		done
		for s in $(list ec2 describe-subnets --filters Name=vpc-id,Values="$v" --query 'Subnets[?DefaultForAz==`true`].SubnetId'); do
			emit aws_default_subnet "$s" "$s"
		done
	done
	for i in $(list ec2 describe-internet-gateways --query 'InternetGateways[].InternetGatewayId'); do
		emit aws_internet_gateway "$i" "$i"
	done
	for n in $(list ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'); do
		emit aws_nat_gateway "$n" "$n"
	done
	for e in $(list ec2 describe-addresses --query 'Addresses[].AllocationId'); do emit aws_eip "$e" "$e"; done
	for rt in $(list ec2 describe-route-tables --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId'); do
		emit aws_route_table "$rt" "$rt"
		while IFS=$'\t' read -r assoc subnet; do
			[[ -n "$subnet" && "$subnet" != None ]] && emit aws_route_table_association "$assoc" "$subnet/$rt"
		done < <(rows ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[?SubnetId].[RouteTableAssociationId,SubnetId]')
	done
	while IFS=$'\t' read -r id name; do emit aws_security_group "${name}_${id}" "$id"; done \
		< <(rows ec2 describe-security-groups --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]")
	for e in $(list ec2 describe-vpc-endpoints --query 'VpcEndpoints[].VpcEndpointId'); do emit aws_vpc_endpoint "$e" "$e"; done
}

svc_ec2() {
	while IFS=$'\t' read -r id name; do emit aws_instance "${name:-$id}" "$id"; done \
		< <(rows ec2 describe-instances --filters Name=instance-state-name,Values=running,stopped \
			--query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]")
	for k in $(list ec2 describe-key-pairs --query 'KeyPairs[].KeyName'); do emit aws_key_pair "$k" "$k"; done
	while IFS=$'\t' read -r id name; do emit aws_launch_template "$name" "$id"; done \
		< <(rows ec2 describe-launch-templates --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]')
	for a in $(list autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].AutoScalingGroupName'); do
		emit aws_autoscaling_group "$a" "$a"
	done
}

svc_elbv2() {
	while IFS=$'\t' read -r arn name; do
		emit aws_lb "$name" "$arn"
		for l in $(list elbv2 describe-listeners --load-balancer-arn "$arn" --query 'Listeners[].ListenerArn'); do
			emit aws_lb_listener "${name}_${l##*/}" "$l"
			for r in $(list elbv2 describe-rules --listener-arn "$l" --query 'Rules[?IsDefault==`false`].RuleArn'); do
				emit aws_lb_listener_rule "${name}_${r##*/}" "$r"
			done
		done
	done < <(rows elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerArn,LoadBalancerName]')
	while IFS=$'\t' read -r arn name; do emit aws_lb_target_group "$name" "$arn"; done \
		< <(rows elbv2 describe-target-groups --query 'TargetGroups[].[TargetGroupArn,TargetGroupName]')
}

svc_ecr() {
	for r in $(list ecr describe-repositories --query 'repositories[].repositoryName'); do
		emit aws_ecr_repository "$r" "$r"
		aws_cmd ecr get-lifecycle-policy --repository-name "$r" >/dev/null && emit aws_ecr_lifecycle_policy "$r" "$r"
	done
}

svc_ecs() {
	for c in $(list ecs list-clusters --query 'clusterArns[]'); do
		cn="${c##*/}"
		emit aws_ecs_cluster "$cn" "$cn"
		for s in $(list ecs list-services --cluster "$cn" --query 'serviceArns[]'); do
			emit aws_ecs_service "${cn}_${s##*/}" "$cn/${s##*/}"
		done
	done
	while IFS=$'\t' read -r arn name; do emit aws_ecs_capacity_provider "$name" "$arn"; done \
		< <(rows ecs describe-capacity-providers \
			--query "capacityProviders[?!contains(['FARGATE','FARGATE_SPOT'], name)].[capacityProviderArn,name]")
	for c in $(list ecs list-clusters --query 'clusterArns[]'); do
		cn="${c##*/}"
		[[ -n "$(list ecs describe-clusters --clusters "$cn" --query 'clusters[0].capacityProviders[]')" ]] &&
			emit aws_ecs_cluster_capacity_providers "$cn" "$cn"
	done
}

svc_appautoscaling() {
	while IFS=$'\t' read -r res dim; do
		emit aws_appautoscaling_target "${res}" "ecs/$res/$dim"
	done < <(rows application-autoscaling describe-scalable-targets --service-namespace ecs \
		--query 'ScalableTargets[].[ResourceId,ScalableDimension]')
	while IFS=$'\t' read -r name res dim; do
		emit aws_appautoscaling_policy "${res}_${name}" "ecs/$res/$dim/$name"
	done < <(rows application-autoscaling describe-scaling-policies --service-namespace ecs \
		--query 'ScalingPolicies[].[PolicyName,ResourceId,ScalableDimension]')

	for f in $(list ecs list-task-definition-families --status ACTIVE --query 'families[]'); do
		td=$(aws_cmd ecs describe-task-definition --task-definition "$f" --query 'taskDefinition.taskDefinitionArn')
		[[ -n "$td" ]] && emit aws_ecs_task_definition "$f" "$td"
	done
}

svc_rds() {
	for c in $(list rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier'); do emit aws_rds_cluster "$c" "$c"; done
	while IFS=$'\t' read -r id cluster; do
		if [[ -n "$cluster" && "$cluster" != None ]]; then
			emit aws_rds_cluster_instance "$id" "$id"
		else
			emit aws_db_instance "$id" "$id"
		fi
	done < <(rows rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBClusterIdentifier]')
	for g in $(list rds describe-db-subnet-groups --query "DBSubnetGroups[?DBSubnetGroupName!='default'].DBSubnetGroupName"); do
		emit aws_db_subnet_group "$g" "$g"
	done
	for g in $(list rds describe-db-parameter-groups --query "DBParameterGroups[?!starts_with(DBParameterGroupName, 'default.')].DBParameterGroupName"); do
		emit aws_db_parameter_group "$g" "$g"
	done
	for g in $(list rds describe-db-cluster-parameter-groups --query "DBClusterParameterGroups[?!starts_with(DBClusterParameterGroupName, 'default.')].DBClusterParameterGroupName"); do
		emit aws_rds_cluster_parameter_group "$g" "$g"
	done
}

svc_rdsproxy() {
	for p in $(list rds describe-db-proxies --query 'DBProxies[].DBProxyName'); do
		emit aws_db_proxy "$p" "$p"
		emit aws_db_proxy_default_target_group "$p" "$p"
		for e in $(list rds describe-db-proxy-endpoints --db-proxy-name "$p" --query 'DBProxyEndpoints[?!IsDefault].DBProxyEndpointName'); do
			emit aws_db_proxy_endpoint "$e" "$p/$e"
		done
		# RDS_INSTANCE targets are derived from the TRACKED_CLUSTER
		while IFS=$'\t' read -r tg id; do
			emit aws_db_proxy_target "${p}_${id}" "$p/$tg/TRACKED_CLUSTER/$id"
		done < <(rows rds describe-db-proxy-targets --db-proxy-name "$p" \
			--query "Targets[?Type=='TRACKED_CLUSTER'].[TargetGroupName || 'default',RdsResourceId]")
	done
}

svc_elasticache() {
	for g in $(list elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId'); do
		emit aws_elasticache_replication_group "$g" "$g"
	done
	for c in $(list elasticache describe-cache-clusters --query 'CacheClusters[?!ReplicationGroupId].CacheClusterId'); do
		emit aws_elasticache_cluster "$c" "$c"
	done
	for c in $(list elasticache describe-serverless-caches --query 'ServerlessCaches[].ServerlessCacheName'); do
		emit aws_elasticache_serverless_cache "$c" "$c"
	done
	for g in $(list elasticache describe-cache-subnet-groups --query "CacheSubnetGroups[?CacheSubnetGroupName!='default'].CacheSubnetGroupName"); do
		emit aws_elasticache_subnet_group "$g" "$g"
	done
}

svc_dynamodb() {
	for t in $(list dynamodb list-tables --query 'TableNames[]'); do emit aws_dynamodb_table "$t" "$t"; done
}

svc_lambda() {
	for f in $(list lambda list-functions --query 'Functions[].FunctionName'); do emit aws_lambda_function "$f" "$f"; done
}

svc_lambdaperm() {
	for f in $(list lambda list-functions --query 'Functions[].FunctionName'); do
		pol=$(aws_cmd lambda get-policy --function-name "$f" --query Policy)
		[[ -z "$pol" ]] && continue
		for sid in $(printf '%s' "$pol" | grep -oE '"Sid":"[^"]+"' | cut -d'"' -f4); do
			emit aws_lambda_permission "${f}_${sid}" "$f/$sid"
		done
	done
}

svc_events() {
	for r in $(list events list-rules --query "Rules[?!starts_with(Name, 'AutoScalingManagedRule')].Name"); do
		emit aws_cloudwatch_event_rule "$r" "$r"
		for t in $(list events list-targets-by-rule --rule "$r" --query 'Targets[].Id'); do
			emit aws_cloudwatch_event_target "${r}_${t}" "default/$r/$t"
		done
	done
	while IFS=$'\t' read -r name group; do emit aws_scheduler_schedule "$name" "$group/$name"; done \
		< <(rows scheduler list-schedules --query 'Schedules[].[Name,GroupName]')
}

svc_apigateway() {
	while IFS=$'\t' read -r id name; do emit aws_apigatewayv2_api "$name" "$id"; done \
		< <(rows apigatewayv2 get-apis --query 'Items[].[ApiId,Name]')
	while IFS=$'\t' read -r id name; do emit aws_api_gateway_rest_api "$name" "$id"; done \
		< <(rows apigateway get-rest-apis --query 'items[].[id,name]')
}

svc_cloudwatch() {
	for g in $(list logs describe-log-groups --query 'logGroups[].logGroupName'); do emit aws_cloudwatch_log_group "$g" "$g"; done
	for d in $(list cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName'); do
		emit aws_cloudwatch_dashboard "$d" "$d"
	done
	for a in $(list cloudwatch describe-alarms --query "MetricAlarms[?!starts_with(AlarmName, 'TargetTracking-')].AlarmName"); do
		emit aws_cloudwatch_metric_alarm "$a" "$a"
	done
}

svc_ses() {
	for i in $(list sesv2 list-email-identities --query 'EmailIdentities[].IdentityName'); do
		emit aws_sesv2_email_identity "$i" "$i"
	done
}

svc_efs() {
	for fs in $(list efs describe-file-systems --query 'FileSystems[].FileSystemId'); do
		emit aws_efs_file_system "$fs" "$fs"
		for mt in $(list efs describe-mount-targets --file-system-id "$fs" --query 'MountTargets[].MountTargetId'); do
			emit aws_efs_mount_target "$mt" "$mt"
		done
		for ap in $(list efs describe-access-points --file-system-id "$fs" --query 'AccessPoints[].AccessPointId'); do
			emit aws_efs_access_point "$ap" "$ap"
		done
		aws_cmd efs describe-file-system-policy --file-system-id "$fs" >/dev/null && emit aws_efs_file_system_policy "$fs" "$fs"
		aws_cmd efs describe-backup-policy --file-system-id "$fs" >/dev/null && emit aws_efs_backup_policy "$fs" "$fs"
	done
}

svc_cognito() {
	for up in $(list cognito-idp list-user-pools --max-results 60 --query 'UserPools[].Id'); do
		emit aws_cognito_user_pool "$up" "$up"
		for c in $(list cognito-idp list-user-pool-clients --user-pool-id "$up" --query 'UserPoolClients[].ClientId'); do
			emit aws_cognito_user_pool_client "$c" "$up/$c"
		done
		dom=$(list cognito-idp describe-user-pool --user-pool-id "$up" --query 'UserPool.Domain')
		[[ -n "$dom" ]] && emit aws_cognito_user_pool_domain "$dom" "$dom"
	done
	for ip in $(list cognito-identity list-identity-pools --max-results 60 --query 'IdentityPools[].IdentityPoolId'); do
		emit aws_cognito_identity_pool "$ip" "$ip"
		[[ -n "$(list cognito-identity get-identity-pool-roles --identity-pool-id "$ip" --query 'Roles')" ]] &&
			emit aws_cognito_identity_pool_roles_attachment "$ip" "$ip"
	done
}

svc_acm() {
	for a in $(list acm list-certificates --query 'CertificateSummaryList[].CertificateArn'); do emit aws_acm_certificate "${a##*/}" "$a"; done
}

svc_wafv2() {
	while IFS=$'\t' read -r id name; do emit aws_wafv2_web_acl "$name" "$id/$name/REGIONAL"; done \
		< <(rows wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].[Id,Name]')
}

svc_eks() {
	for c in $(list eks list-clusters --query 'clusters[]'); do
		emit aws_eks_cluster "$c" "$c"
		for ng in $(list eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]'); do
			emit aws_eks_node_group "${c}_${ng}" "$c:$ng"
		done
		for a in $(list eks list-addons --cluster-name "$c" --query 'addons[]'); do
			emit aws_eks_addon "${c}_${a}" "$c:$a"
		done
		for p in $(list eks list-fargate-profiles --cluster-name "$c" --query 'fargateProfileNames[]'); do
			emit aws_eks_fargate_profile "${c}_${p}" "$c:$p"
		done
	done
}

svc_sfn() {
	while IFS=$'\t' read -r arn name; do emit aws_sfn_state_machine "$name" "$arn"; done \
		< <(rows stepfunctions list-state-machines --query 'stateMachines[].[stateMachineArn,name]')
}

svc_kinesis() {
	for s in $(list kinesis list-streams --query 'StreamNames[]'); do emit aws_kinesis_stream "$s" "$s"; done
	for s in $(list firehose list-delivery-streams --query 'DeliveryStreamNames[]'); do
		arn=$(aws_cmd firehose describe-delivery-stream --delivery-stream-name "$s" --query 'DeliveryStreamDescription.DeliveryStreamARN')
		[[ -n "$arn" ]] && emit aws_kinesis_firehose_delivery_stream "$s" "$arn"
	done
}

svc_cloudtrail() {
	while IFS=$'\t' read -r arn name home; do
		[[ "$home" != "$REGION" ]] && continue
		emit aws_cloudtrail "$name" "$arn"
	done < <(rows cloudtrail describe-trails --no-include-shadow-trails --query 'trailList[].[TrailARN,Name,HomeRegion]')
}

svc_backup() {
	for v in $(list backup list-backup-vaults --query "BackupVaultList[?!starts_with(BackupVaultName, 'aws/')].BackupVaultName"); do
		emit aws_backup_vault "$v" "$v"
	done
	while IFS=$'\t' read -r id name; do emit aws_backup_plan "$name" "$id"; done \
		< <(rows backup list-backup-plans --query 'BackupPlansList[].[BackupPlanId,BackupPlanName]')
}

svc_opensearch() {
	for d in $(list opensearch list-domain-names --query 'DomainNames[].DomainName'); do emit aws_opensearch_domain "$d" "$d"; done
}

svc_codebuild() {
	for p in $(list codebuild list-projects --query 'projects[]'); do emit aws_codebuild_project "$p" "$p"; done
	for p in $(list codepipeline list-pipelines --query 'pipelines[].name'); do emit aws_codepipeline "$p" "$p"; done
}

svc_iam() {
	ROLES=$(list iam list-roles --query "Roles[?!starts_with(Path, '/aws-service-role/') && !starts_with(Path, '/aws-reserved/') && !starts_with(Path, '/service-role/aws')].RoleName")
	for r in $ROLES; do
		emit aws_iam_role "$r" "$r"
		for p in $(list iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn'); do
			emit aws_iam_role_policy_attachment "${r}_${p##*/}" "$r/$p"
		done
		for p in $(list iam list-role-policies --role-name "$r" --query 'PolicyNames[]'); do
			emit aws_iam_role_policy "${r}_${p}" "$r:$p"
		done
	done
	for ip in $(list iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName'); do
		emit aws_iam_instance_profile "$ip" "$ip"
	done
	for u in $(list iam list-users --query 'Users[].UserName'); do
		emit aws_iam_user "$u" "$u"
		for p in $(list iam list-attached-user-policies --user-name "$u" --query 'AttachedPolicies[].PolicyArn'); do
			emit aws_iam_user_policy_attachment "${u}_${p##*/}" "$u/$p"
		done
		for p in $(list iam list-user-policies --user-name "$u" --query 'PolicyNames[]'); do
			emit aws_iam_user_policy "${u}_${p}" "$u:$p"
		done
		groups=$(list iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' | paste -sd/)
		[[ -n "$groups" ]] && emit aws_iam_user_group_membership "${u}_groups" "$u/$groups"
	done
	for g in $(list iam list-groups --query 'Groups[].GroupName'); do
		emit aws_iam_group "$g" "$g"
		for p in $(list iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyArn'); do
			emit aws_iam_group_policy_attachment "${g}_${p##*/}" "$g/$p"
		done
	done
	while IFS=$'\t' read -r arn name; do emit aws_iam_policy "$name" "$arn"; done \
		< <(rows iam list-policies --scope Local --query 'Policies[].[Arn,PolicyName]')
	for a in $(list iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn'); do
		emit aws_iam_openid_connect_provider "${a##*/}" "$a"
	done
}

svc_cloudfront() {
	while IFS=$'\t' read -r id comment; do emit aws_cloudfront_distribution "${comment:-$id}_$id" "$id"; done \
		< <(rows cloudfront list-distributions --query 'DistributionList.Items[].[Id,Comment]')
	while IFS=$'\t' read -r id name; do emit aws_cloudfront_origin_access_control "$name" "$id"; done \
		< <(rows cloudfront list-origin-access-controls --query 'OriginAccessControlList.Items[].[Id,Name]')
	for name in $(list cloudfront list-functions --query 'FunctionList.Items[].Name' | sort -u); do
		emit aws_cloudfront_function "$name" "$name"
	done
}

svc_route53() {
	while IFS=$'\t' read -r zid zname; do
		zid="${zid##*/}"
		zname="${zname%.}"
		emit aws_route53_zone "$zname" "$zid"
		while IFS=$'\t' read -r rname rtype setid; do
			rname="${rname%.}"
			rname="${rname//\\052/*}"
			[[ "$rname" == "$zname" && ("$rtype" == NS || "$rtype" == SOA) ]] && continue
			id="${zid}_${rname}_${rtype}"
			[[ -n "${setid:-}" && "$setid" != None ]] && id="${id}_${setid}"
			emit aws_route53_record "${rname}_${rtype}" "$id"
		done < <(rows route53 list-resource-record-sets --hosted-zone-id "$zid" \
			--query 'ResourceRecordSets[].[Name,Type,SetIdentifier]')
	done < <(rows route53 list-hosted-zones --query 'HostedZones[].[Id,Name]')
}

svc_wafv2cf() {
	# CloudFront-scoped WAF lives in us-east-1 regardless of provider region
	local at=""
	[[ "$PRIMARY" != us-east-1 ]] && at="@us-east-1"
	while IFS=$'\t' read -r id name; do emit aws_wafv2_web_acl "$name" "$id/$name/CLOUDFRONT$at"; done \
		< <(aws --profile "$PROFILE" --region us-east-1 --output text wafv2 list-web-acls --scope CLOUDFRONT \
			--query 'WebACLs[].[Id,Name]' 2>/dev/null | tr -d '\r' | grep -v -E '^(None)?$')
}

# ---------- Main ----------
echo "# Generated by discover.sh at $(date -u +%FT%TZ) - profile=$PROFILE regions=$REGIONS" >"$OUT"
[[ -n "$FILTER" ]] && echo "# filter=$FILTER" >>"$OUT"

SCOPE=global
REGION="$PRIMARY"
for s in $GLOBAL_SERVICES; do wanted "$s" && run "$s"; done

SCOPE=regional
for REGION in "${REGION_LIST[@]}"; do
	for s in $REGIONAL_SERVICES; do wanted "$s" && run "$s"; done
done

echo
echo "OK: $COUNT resources -> $OUT"
[[ -n "$FILTER" ]] && echo "Skipped by --filter: $SKIPPED"
echo "Next: terraform init && terraform plan -generate-config-out=generated.tf"
