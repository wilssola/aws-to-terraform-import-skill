// Patches known incompatibilities in HCL produced by `terraform plan -generate-config-out`.
// Usage: bun fix-generated.ts [file.tf ...] [--dir <tf-dir>] [--profile <p>] [--region <r>]
//          [--ignore-deploy-drift] [--post-import]
// Default mode runs before import. --post-import runs after `apply` on all *.tf files and only
// applies fixes that would show a (harmless) diff if applied before the import.
// Idempotent: safe to re-run after regenerating.
import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { awsCli, cli, mapResources } from "./lib.ts";

const { root, profile, region, positionals, flag } = cli(["ignore-deploy-drift", "post-import"]);
const postImport = flag("post-import");
const ignoreDeployDrift = flag("ignore-deploy-drift");
const files = positionals.length
	? positionals
	: postImport
		? readdirSync(root).filter((f) => f.endsWith(".tf"))
		: ["generated.tf"];
// AWS CLI bound to the resource's own region (multi-region imports set `region = "..."`)
const awsFor = (block: string) =>
	awsCli(profile, block.match(/^\s+region\s+= "([a-z0-9-]+)"$/m)?.[1] ?? region);

const removeAttrs = (body: string, names: string[]) =>
	body.replace(new RegExp(`^\\s+(${names.join("|")})\\s+=.*\\n`, "gm"), "");

const removeBlocks = (body: string, names: string[]) =>
	body.replace(new RegExp(`^(\\s+)(${names.join("|")}) \\{\\n[\\s\\S]*?^\\1\\}\\n`, "gm"), "");

const addLifecycle = (body: string, ignore: string[]) =>
	body.includes("lifecycle {")
		? body
		: body.replace(/\n\}$/, `\n  lifecycle {\n    ignore_changes = [${ignore.join(", ")}]\n  }\n}`);

// Generated routes use "" instead of null, which fails CIDR validation
const fixRoutes = (body: string) =>
	body.replace(/^(\s+route = \[[\s\S]*?^\s+\}\])/m, (r) => r.replace(/= ""$/gm, "= null"));

// `target_group_arn` + `forward` in the same action cause a perpetual diff after import; keep only
// `forward`. Post-import only: applied before the import it shows as an in-place change instead.
const dedupeForward = (body: string) =>
	body.replace(/^ {2}(default_)?action \{\n[\s\S]*?^ {2}\}\n/gm, (action) =>
		action.includes("forward {")
			? action.replace(/^( {4}target_group_arn\s+= )".+"$/m, "$1null")
			: action,
	);

const subnetConflicts = [
	"availability_zone_id",
	"enable_lni_at_device_index",
	"map_customer_owned_ip_on_launch",
	"customer_owned_ipv4_pool",
	"outpost_arn",
];

type Fix = (body: string, name: string) => Promise<string> | string;

const fixes: Record<string, Fix> = {
	aws_route_table: fixRoutes,
	aws_default_route_table: fixRoutes,
	aws_vpc_endpoint: (b) => removeAttrs(b, ["private_dns_specified_domains"]),
	aws_subnet: (b) => removeAttrs(b, subnetConflicts),
	aws_default_subnet: (b) => removeAttrs(b, subnetConflicts),
	aws_default_vpc: (b) => removeAttrs(b, ["ipv6_netmask_length", "ipv6_ipam_pool_id"]),
	aws_vpc: (b) => removeAttrs(b, ["ipv6_netmask_length", "ipv6_ipam_pool_id"]),
	aws_cognito_user_pool_client: (b) => b.replace(/^\s+(access|id)_token_validity\s+= 0\n/gm, ""),
	aws_launch_template: (b) => removeAttrs(b, ["security_group_names"]),
	aws_instance: (b) =>
		removeBlocks(removeAttrs(b, ["ipv6_addresses"]), ["primary_network_interface"]),
	aws_autoscaling_group: (b) =>
		addLifecycle(removeAttrs(b, ["availability_zones"]), [
			"force_delete",
			"force_delete_warm_pool",
			"ignore_failed_scaling_activities",
			"wait_for_capacity_timeout",
		]),
	aws_lb: (b) => removeBlocks(b, ["subnet_mapping"]),
	aws_lb_listener: (b) =>
		/mode\s+= "off"/.test(b) ? removeBlocks(b, ["mutual_authentication"]) : b,
	aws_lb_listener_rule: (b) => {
		const weighted = (b.match(/^\s+target_group \{/gm) ?? []).length > 1;
		return ignoreDeployDrift && weighted ? addLifecycle(b, ["action"]) : b;
	},
	aws_lb_target_group: (b) =>
		removeBlocks(b.replace(/^\s+target_control_port\s+= 0\n/m, ""), [
			"target_failover",
			"target_health_state",
		]),
	aws_ecs_service: (b) =>
		ignoreDeployDrift
			? addLifecycle(b, ["task_definition", "desired_count", "wait_for_steady_state"])
			: addLifecycle(b, ["wait_for_steady_state"]),
	aws_cloudfront_function: (b) => addLifecycle(b, ["publish"]),
	aws_cloudfront_origin_access_control: (b) =>
		/description\s+= null/.test(b) ? addLifecycle(b, ["description"]) : b,
	aws_nat_gateway: (b) =>
		addLifecycle(b, ["secondary_allocation_ids", "secondary_private_ip_addresses"]),
	aws_secretsmanager_secret: (b) =>
		addLifecycle(b, ["recovery_window_in_days", "force_overwrite_replica_secret"]),
	aws_key_pair: async (b, name) => {
		if (!/public_key\s+= "/.test(b)) {
			const keyName = b.match(/key_name\s+= "(.+)"/)?.[1] ?? name;
			const key = await awsFor(b)(
				"ec2",
				"describe-key-pairs",
				"--key-names",
				keyName,
				"--include-public-key",
				"--query",
				"KeyPairs[0].PublicKey",
			);
			b = removeAttrs(b, ["public_key"]).replace(/\n\}$/, `\n  public_key = "${key}"\n}`);
		}
		return addLifecycle(b, ["public_key"]);
	},
	// Zip Lambdas need local code: download it to lambda/<name>.zip
	aws_lambda_function: async (b) => {
		if (!/filename\s+= null/.test(b) || !/package_type\s+= "Zip"/.test(b)) return b;
		const fn = b.match(/function_name\s+= "(.+)"/)?.[1];
		if (!fn) return b;
		const zip = join(root, "lambda", `${fn}.zip`);
		if (!existsSync(zip)) {
			mkdirSync(join(root, "lambda"), { recursive: true });
			const url = await awsFor(b)(
				"lambda",
				"get-function",
				"--function-name",
				fn,
				"--query",
				"Code.Location",
			);
			await Bun.write(zip, await fetch(url));
		}
		b = b.replace(/^(\s+)filename(\s+)= null$/m, `$1filename$2= "lambda/${fn}.zip"`);
		return addLifecycle(b, ["filename"]);
	},
};

const postImportFixes: Record<string, Fix> = {
	aws_lb_listener: dedupeForward,
	aws_lb_listener_rule: dedupeForward,
};

const active = postImport ? postImportFixes : fixes;
for (const name of files) {
	const file = join(root, name);
	const { text, changed } = await mapResources(await Bun.file(file).text(), (block, type, n) =>
		active[type] ? active[type](block, n) : block,
	);
	if (changed) await Bun.write(file, text);
	console.log(
		`fix-generated${postImport ? " --post-import" : ""}: ${changed} resources patched in ${name}`,
	);
}
