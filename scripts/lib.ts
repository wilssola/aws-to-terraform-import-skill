// Shared helpers for the skill scripts.
import { resolve } from "node:path";
import { parseArgs } from "node:util";

// Region configured for the profile in ~/.aws/config, falling back to us-east-1
const profileRegion = (profile: string) => {
	const proc = Bun.spawnSync(["aws", "configure", "get", "region", "--profile", profile]);
	return proc.stdout.toString().trim() || "us-east-1";
};

// Parses common flags (--dir, --profile, --region) plus script-specific boolean flags
export const cli = (flags: string[] = []) => {
	const { values, positionals } = parseArgs({
		args: Bun.argv.slice(2),
		allowPositionals: true,
		options: {
			dir: { type: "string" },
			profile: { type: "string" },
			region: { type: "string" },
			...Object.fromEntries(flags.map((f) => [f, { type: "boolean" as const }])),
		},
	});
	const str = (v: unknown) => (typeof v === "string" ? v : undefined);
	const profile =
		str(values.profile) ?? process.env.AWS_PROFILE_TF ?? process.env.AWS_PROFILE ?? "default";
	return {
		flag: (name: string) => (values as Record<string, unknown>)[name] === true,
		positionals,
		root: resolve(str(values.dir) ?? process.env.TF_DIR ?? process.cwd()),
		profile,
		region:
			str(values.region) ??
			process.env.AWS_REGION_TF ??
			process.env.AWS_REGION ??
			profileRegion(profile),
	};
};

export const awsCli =
	(profile: string, region: string) =>
	async (...args: string[]) => {
		const proc = Bun.spawn(
			["aws", "--profile", profile, "--region", region, "--output", "text", ...args],
			{
				stderr: "pipe",
			},
		);
		const out = (await new Response(proc.stdout).text()).trim();
		if ((await proc.exited) !== 0) {
			throw new Error(`aws ${args.join(" ")} failed: ${await new Response(proc.stderr).text()}`);
		}
		return out;
	};

// Iterates top-level `resource` blocks, replacing each with the callback result.
export const mapResources = async (
	src: string,
	fn: (block: string, type: string, name: string) => Promise<string> | string,
) => {
	let out = "";
	let last = 0;
	let changed = 0;
	for (const m of src.matchAll(/^resource "(\w+)" "(\w+)" \{\n[\s\S]*?^\}$/gm)) {
		const [block, type, name] = m;
		const next = await fn(block, type, name);
		if (next !== block) changed++;
		out += src.slice(last, m.index) + next;
		last = (m.index ?? 0) + block.length;
	}
	return { text: out + src.slice(last), changed };
};
