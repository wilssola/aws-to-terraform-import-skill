// Replaces hardcoded IDs/ARNs with references to resources in state (e.g. "vpc-123" -> aws_vpc.x.id).
// - Exact match on state `id`/`arn` values; ARNs with a suffix (/..., :...) become interpolations.
// - Plain names (bucket, role...) only in allow-listed attributes, to avoid false positives.
// - Skips self-references, `tags`/`tags_all`, heredocs and edges that would create a cycle.
// Usage: bun link-references.ts [--dir <tf-dir>]   (runs `terraform show -json` itself)
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { cli } from "./lib.ts";

const { root } = cli();

type StateResource = { address: string; type: string; values: Record<string, unknown> };

const show = Bun.spawn(["terraform", "show", "-json"], { cwd: root, stderr: "inherit" });
const stateJson = await new Response(show.stdout).text();
if ((await show.exited) !== 0) throw new Error("terraform show -json failed");
const state = JSON.parse(stateJson);
const resources: StateResource[] = state.values?.root_module?.resources ?? [];
if (!resources.length) {
	console.error(`link-references: no resources in state at ${root} (run after import; use --dir)`);
	process.exit(1);
}

// Literals that are unambiguous AWS identifiers (any partition)
const idPattern =
	/^(arn:aws[a-z-]*:|(vpc|subnet|sg|rtb|igw|eigw|nat|eipalloc|eni|fs|fsmt|fsap|lt|acl|dopt|vpce|tgw|tgw-attach|pcx|vgw|cgw|vpn|pl|i|vol|ami|snap|key|cluster|lb|tg|r|e)-[0-9a-z]{6,}$|https:\/\/sqs\.)/;

// Attribute -> resource types its plain (non-ARN) name may reference
const nameKeys = new Map<string, RegExp>([
	["bucket", /^aws_s3_bucket$/],
	["role", /^aws_iam_role$/],
	["role_name", /^aws_iam_role$/],
	["user", /^aws_iam_user$/],
	["group", /^aws_iam_group$/],
	["function_name", /^aws_lambda_function$/],
	["repository", /^aws_ecr_repository$/],
	["key_name", /^aws_key_pair$/],
	["cluster_identifier", /^aws_rds_cluster$/],
	["db_subnet_group_name", /^aws_db_subnet_group$/],
	["subnet_group_name", /^aws_elasticache_subnet_group$/],
	["iam_instance_profile", /^aws_iam_instance_profile$/],
	["db_proxy_name", /^aws_db_proxy$/],
	["user_pool_id", /^aws_cognito_user_pool$/],
	["identity_pool_id", /^aws_cognito_identity_pool$/],
	["file_system_id", /^aws_efs_file_system$/],
	["log_group_name", /^aws_cloudwatch_log_group$/],
	["rule", /^aws_cloudwatch_event_rule$/],
	["rest_api_id", /^aws_api_gateway_rest_api$/],
	["api_id", /^aws_apigatewayv2_api$/],
	["zone_id", /^aws_route53_zone$/],
	["table_name", /^aws_dynamodb_table$/],
	["autoscaling_group_name", /^aws_autoscaling_group$/],
	["cluster_name", /^aws_(eks_cluster|ecs_cluster)$/],
]);

// value -> every state reference that exposes it as `id` or `arn`
const byValue = new Map<string, string[]>();
for (const r of resources) {
	for (const attr of ["arn", "id"]) {
		const v = r.values[attr];
		if (typeof v !== "string" || v.length <= 3) continue;
		const refs = byValue.get(v) ?? byValue.set(v, []).get(v);
		refs?.push(`${r.address}.${attr}`);
	}
}

// Picks one reference for a value. Plain names must hit an allowed type and be unambiguous.
const pick = (value: string, key: string | undefined): string | undefined => {
	const refs = byValue.get(value);
	if (!refs?.length) return;
	if (idPattern.test(value)) {
		// Same ID on parent + child (e.g. bucket and bucket_policy): the shortest type is the parent
		return [...refs].sort((a, b) => a.split(".")[0].length - b.split(".")[0].length)[0];
	}
	const allowed = key ? nameKeys.get(key) : undefined;
	if (!allowed) return;
	const matches = refs.filter((ref) => allowed.test(ref.split(".")[0]));
	const owners = new Set(matches.map(owner));
	return owners.size === 1 ? matches[0] : undefined;
};

const arnPrefixes = [...byValue.keys()]
	.filter((v) => /^arn:aws[a-z-]*:/.test(v))
	.sort((a, b) => b.length - a.length);

// Dependency graph to avoid cycles
const edges = new Map<string, Set<string>>();
const addEdge = (from: string, to: string) =>
	(edges.get(from) ?? edges.set(from, new Set()).get(from))?.add(to);
const reaches = (from: string, to: string) => {
	const seen = new Set<string>();
	const stack = [from];
	while (stack.length) {
		const n = stack.pop() as string;
		if (n === to) return true;
		if (seen.has(n)) continue;
		seen.add(n);
		stack.push(...(edges.get(n) ?? []));
	}
	return false;
};
const tryLink = (from: string, to: string) => {
	if (from === to) return false;
	if (edges.get(from)?.has(to)) return true;
	if (reaches(to, from)) return false;
	addEdge(from, to);
	return true;
};

function owner(ref: string) {
	return ref.split(".").slice(0, 2).join(".");
}

const resolve = (literal: string, key: string | undefined, self: string): string | undefined => {
	const exact = pick(literal, key);
	if (exact) return tryLink(self, owner(exact)) ? exact : undefined;
	if (!/^arn:aws[a-z-]*:/.test(literal)) return;
	const prefix = arnPrefixes.find(
		(p) => literal.startsWith(p) && /^[/:]/.test(literal.slice(p.length)),
	);
	if (!prefix) return;
	const ref = pick(prefix, undefined);
	if (!ref) return;
	return tryLink(self, owner(ref)) ? `"\${${ref}}${literal.slice(prefix.length)}"` : undefined;
};

// Seed the graph with references already present, so new edges cannot close a cycle with them
const existingRef = /\b(aws_\w+\.\w+)\.\w+/g;
for (const file of readdirSync(root).filter((f) => f.endsWith(".tf"))) {
	let self: string | undefined;
	for (const line of (await Bun.file(join(root, file)).text()).split("\n")) {
		const res = line.match(/^resource "(\w+)" "(\w+)" \{/);
		if (res) self = `${res[1]}.${res[2]}`;
		else if (line === "}") self = undefined;
		else if (self)
			for (const m of line.matchAll(existingRef)) if (m[1] !== self) addEdge(self, m[1]);
	}
}

const skip = new Set(["imports.tf", "versions.tf", "providers.tf", "variables.tf", "backend.tf"]);
const files = readdirSync(root).filter((f) => f.endsWith(".tf") && !skip.has(f));

let total = 0;
for (const file of files) {
	const lines = (await Bun.file(join(root, file)).text()).split("\n");
	let self: string | undefined;
	let tagsDepth = 0;
	let heredoc: string | undefined;
	let changed = 0;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		const res = line.match(/^resource "(\w+)" "(\w+)" \{/);
		if (res) {
			self = `${res[1]}.${res[2]}`;
			continue;
		}
		if (line === "}") {
			self = undefined;
			continue;
		}
		if (!self) continue;
		if (heredoc) {
			if (line.trim() === heredoc) heredoc = undefined;
			continue;
		}
		const hd = line.match(/<<-?(\w+)\s*$/);
		if (hd) {
			heredoc = hd[1];
			continue;
		}
		if (tagsDepth > 0 || /^\s+tags(_all)?\s+=\s+\{\s*$/.test(line)) {
			tagsDepth += (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length;
			continue;
		}

		const key = line.match(/^\s*(\w+)\s*=/)?.[1];
		const next = line.replace(/"((?:[^"\\$]|\\.)+)"/g, (m, literal: string, offset: number) => {
			// Do not replace object keys ("aws:SourceArn" = ...)
			if (/^\s*=/.test(line.slice(offset + m.length)) && !/=\s*$/.test(line.slice(0, offset)))
				return m;
			const ref = resolve(literal, key, self as string);
			return ref ?? m;
		});
		if (next !== line) {
			lines[i] = next;
			changed++;
		}
	}
	if (changed) {
		await Bun.write(join(root, file), lines.join("\n"));
		console.log(`${file.padEnd(20)} ${changed} lines`);
		total += changed;
	}
}
console.log(`link-references: ${total} lines changed`);
