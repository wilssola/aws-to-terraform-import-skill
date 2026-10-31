// Compares the account inventory (AWS Resource Explorer) with Terraform state and lists what is not managed.
// Requires an aggregator index: `aws resource-explorer-2 list-indexes` (create one if missing).
// Usage: bun audit-coverage.ts [--dir <tf-dir>] [--profile <p>] [--region <aggregator-region>]
import { awsCli, cli } from "./lib.ts";

const { root, profile, region } = cli();
const aws = awsCli(profile, region);

// Resource types AWS creates/manages itself, or that are noise for IaC
const noise = [
	/^ec2:network-interface$/,
	/^ec2:security-group-rule$/,
	/^ec2:volume$/,
	/^ecs:task-definition$/,
	/^ecs:task$/,
	/^rds:cluster-snapshot$/,
	/^rds:snapshot$/,
	/^memorydb:/,
	/^elasticache:user$/,
	/^resource-explorer-2:/,
	/^apprunner:autoscalingconfiguration$/,
	/^xray:sampling-rule$/,
	/^events:event-bus$/,
	/^athena:datacatalog$/,
	/^cloudformation:stack$/,
	/^iam:mfa$/,
	/^lambda:function\/version$/,
];

// ARNs of AWS-managed resources: service-linked/SSO roles, default parameter/option groups
const noiseArn = [
	/:role\/aws-service-role\//,
	/:role\/aws-reserved\//,
	/:(pg|cluster-pg|og):default[.:]/,
];

const inventory: { arn: string; type: string; region: string }[] = [];
let token: string | undefined;
do {
	const page = JSON.parse(
		await aws(
			"resource-explorer-2",
			"list-resources",
			"--output",
			"json",
			"--max-results",
			"1000",
			...(token ? ["--next-token", token] : []),
		),
	);
	for (const r of page.Resources ?? [])
		inventory.push({ arn: r.Arn, type: r.ResourceType, region: r.Region });
	token = page.NextToken;
} while (token);

const show = Bun.spawn(["terraform", "show", "-json"], { cwd: root, stderr: "inherit" });
const state = JSON.parse(await new Response(show.stdout).text());
const managed = new Set<string>();
const collect = (value: unknown) => {
	if (typeof value === "string") managed.add(value);
	else if (Array.isArray(value)) value.forEach(collect);
	else if (value && typeof value === "object") Object.values(value).forEach(collect);
};
for (const r of state.values?.root_module?.resources ?? []) {
	collect(r.values.id);
	collect(r.values.arn);
	collect(r.values.name);
}

// Last ARN segment (vpc-123, my-bucket, role-name...) also counts as a match
const tail = (arn: string) => arn.split(/[:/]/).filter(Boolean).at(-1) ?? arn;
const missing = inventory.filter(
	(r) =>
		!noise.some((n) => n.test(r.type)) &&
		!noiseArn.some((n) => n.test(r.arn)) &&
		!managed.has(r.arn) &&
		!managed.has(tail(r.arn)),
);

const byKey = new Map<string, string[]>();
for (const r of missing) {
	const key = `${r.region.padEnd(12)} ${r.type}`;
	byKey.set(key, [...(byKey.get(key) ?? []), tail(r.arn)]);
}
console.log(
	`inventory: ${inventory.length}  state: ${state.values?.root_module?.resources?.length ?? 0}  unmanaged: ${missing.length}\n`,
);
for (const [key, names] of [...byKey].sort()) {
	console.log(
		`${String(names.length).padStart(4)}  ${key}  ${names.slice(0, 4).join(", ")}${names.length > 4 ? ", ..." : ""}`,
	);
}
