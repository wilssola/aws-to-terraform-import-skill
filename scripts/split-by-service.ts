// Moves `resource` blocks from generated*.tf into per-service files (rds.tf, ecs.tf...).
// Text-only move: resource addresses do not change, so state is unaffected.
// Usage: bun split-by-service.ts [file.tf ...] [--dir <tf-dir>]   (default: generated*.tf)
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cli } from "./lib.ts";

const { root, positionals } = cli();

const groups: [file: string, prefixes: string[]][] = [
	[
		"network.tf",
		[
			"aws_vpc",
			"aws_default_",
			"aws_subnet",
			"aws_route",
			"aws_internet_gateway",
			"aws_egress_only_internet_gateway",
			"aws_nat_gateway",
			"aws_eip",
			"aws_network_acl",
			"aws_vpn_",
			"aws_customer_gateway",
			"aws_ec2_transit_gateway",
		],
	],
	["security-groups.tf", ["aws_security_group", "aws_vpc_security_group_"]],
	["iam.tf", ["aws_iam_"]],
	["s3.tf", ["aws_s3_"]],
	["rds.tf", ["aws_rds_", "aws_db_"]],
	["elasticache.tf", ["aws_elasticache_"]],
	["dynamodb.tf", ["aws_dynamodb_"]],
	["ecs.tf", ["aws_ecs_", "aws_appautoscaling_"]],
	["ecr.tf", ["aws_ecr_"]],
	[
		"ec2.tf",
		[
			"aws_instance",
			"aws_key_pair",
			"aws_launch_template",
			"aws_autoscaling_",
			"aws_ebs_",
			"aws_ami",
		],
	],
	["alb.tf", ["aws_lb", "aws_alb"]],
	["cloudfront.tf", ["aws_cloudfront_", "aws_wafv2_"]],
	["acm.tf", ["aws_acm_"]],
	["route53.tf", ["aws_route53_"]],
	["sqs-sns.tf", ["aws_sqs_", "aws_sns_"]],
	["lambda.tf", ["aws_lambda_"]],
	["api-gateway.tf", ["aws_api_gateway_", "aws_apigatewayv2_"]],
	["events.tf", ["aws_cloudwatch_event_", "aws_scheduler_"]],
	["monitoring.tf", ["aws_cloudwatch_"]],
	["secrets.tf", ["aws_secretsmanager_", "aws_ssm_", "aws_kms_"]],
	["efs.tf", ["aws_efs_"]],
	["cognito.tf", ["aws_cognito_"]],
	["ses.tf", ["aws_ses"]],
];

// Longest prefix wins: aws_route53_ beats aws_route, aws_cloudwatch_event_ beats aws_cloudwatch_
const rules = groups
	.flatMap(([file, prefixes]) => prefixes.map((p) => ({ file, p })))
	.sort((a, b) => b.p.length - a.p.length);

const target = (type: string) => rules.find(({ p }) => type.startsWith(p))?.file ?? "misc.tf";

const inputs = positionals.length
	? positionals
	: readdirSync(root).filter((f) => /^generated.*\.tf$/.test(f));
if (!inputs.length) {
	console.log("split-by-service: no generated*.tf files found");
	process.exit(0);
}

const buckets = new Map<string, string[]>();
let total = 0;
for (const input of inputs) {
	const src = await Bun.file(join(root, input)).text();
	for (const m of src.matchAll(/^resource "(\w+)" "\w+" \{\n[\s\S]*?^\}$/gm)) {
		const file = target(m[1]);
		buckets.set(file, [...(buckets.get(file) ?? []), m[0]]);
		total++;
	}
}

for (const [file, blocks] of buckets) {
	const path = join(root, file);
	const prev = (await Bun.file(path).exists())
		? `${(await Bun.file(path).text()).trimEnd()}\n\n`
		: "";
	await Bun.write(path, `${prev}${blocks.join("\n\n")}\n`);
	console.log(`${file.padEnd(20)} +${blocks.length}`);
}
for (const input of inputs) rmSync(join(root, input));
console.log(`split-by-service: ${total} resources from ${inputs.join(", ")}`);
