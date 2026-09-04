#!/usr/bin/env node
// lore: generate INDEX.md and .claude/rules/knowledge/*.md from the frontmatter of
// docs/ai-knowledge/*.md. The index and rules are artifacts — the single source of
// truth is each knowledge file's frontmatter, which kills "the index says one thing,
// the file says another".
//
// Usage:
//   node gen-knowledge-index.mjs [repoRoot]          generate/update INDEX.md + rules, prune orphan rules
//   node gen-knowledge-index.mjs [repoRoot] --check  CI mode: no writes; invalid frontmatter / dead anchors / artifact drift → exit 1
//
// Also emits docs/ai-knowledge/{AGENTS,CLAUDE}.md — the write-gate policy files (nested
// runtime instructions: reads stay open, writes must go through lore flows). They are
// generated artifacts like INDEX.md: identical across repos, drift-checked by --check.
import {readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, rmSync, statSync, lstatSync, realpathSync, renameSync, utimesSync} from 'node:fs';
import {join, dirname, basename, resolve, sep} from 'node:path';

const args = process.argv.slice(2);
const check = args.includes('--check');
// --strict promotes lint hints (broad descriptions, directory anchors, oversized files) to errors
const strict = args.includes('--strict');
const repoRoot = resolve(args.find((a) => !a.startsWith('--')) || process.cwd());
const kbDir = join(repoRoot, 'docs', 'ai-knowledge');
const rulesDir = join(repoRoot, '.claude', 'rules', 'knowledge');

// ---------- symlink containment (write mode) ----------
// This generator runs automatically inside skill flows, so a malicious repo must not be able
// to point its writes outside itself: a symlinked docs/ai-knowledge/, rules dir, or target
// file would otherwise let INDEX/rules/gate/.gitattributes writes (and orphan deletion) land
// on arbitrary paths. Directory components are realpath-checked against the repo root, and a
// target whose final component is a symlink is refused outright.
const realRoot = (() => {
	try {
		return realpathSync(repoRoot);
	} catch {
		return repoRoot;
	}
})();
const inRoot = (p) => p === realRoot || p.startsWith(realRoot + sep);
function safeWrite(absPath, content, label) {
	mkdirSync(dirname(absPath), {recursive: true});
	const realDir = realpathSync(dirname(absPath));
	if (!inRoot(realDir)) {
		console.error(`[gen-knowledge-index] refusing to write ${label}: its directory resolves outside the repo (${realDir})`);
		process.exit(1);
	}
	let st = null;
	try {
		st = lstatSync(absPath);
	} catch {}
	if (st && st.isSymbolicLink()) {
		console.error(`[gen-knowledge-index] refusing to write ${label}: the target is a symlink`);
		process.exit(1);
	}
	writeFileSync(join(realDir, basename(absPath)), content);
}
function assertDirInRoot(dir, label) {
	if (!existsSync(dir)) return;
	const real = realpathSync(dir);
	if (!inRoot(real)) {
		console.error(`[gen-knowledge-index] ${label} resolves outside the repo (${real}) — refusing to operate on it`);
		process.exit(1);
	}
}

if (!existsSync(kbDir)) {
	// In --check mode a missing knowledge dir is only benign when nothing it owns is left
	// behind: a PR that deletes docs/ai-knowledge/ but keeps the generated rules (or the
	// .gitattributes union lines) must fail, or the repo keeps stale artifacts forever.
	if (check) {
		const leftovers = existsSync(rulesDir) ? readdirSync(rulesDir).filter((f) => f.endsWith('.md')) : [];
		if (leftovers.length) {
			console.error(`[drift] ${kbDir} is gone but ${leftovers.length} generated rule file(s) remain under .claude/rules/knowledge/ — delete them (or restore the knowledge dir)`);
			process.exit(1);
		}
		const gaP = join(repoRoot, '.gitattributes');
		if (existsSync(gaP)) {
			const stale = readFileSync(gaP, 'utf8')
				.split('\n')
				.filter((l) => /^(docs\/ai-knowledge\/|\.claude\/rules\/knowledge\/).* (merge=union |linguist-generated)/.test(l.trim()));
			if (stale.length) {
				console.error(`[drift] ${kbDir} is gone but ${stale.length} lore .gitattributes line(s) remain — delete them (or restore the knowledge dir)`);
				process.exit(1);
			}
		}
		console.log('[gen-knowledge-index] check passed: repo is not onboarded (no docs/ai-knowledge/, no leftover artifacts)');
		process.exit(0);
	}
	console.error(`[gen-knowledge-index] ${kbDir} does not exist (repo not onboarded); run lore:init first`);
	process.exit(1);
}

// ---------- concurrency lock (write mode only; --check is read-only and lock-free, zero CI impact) ----------
// When multiple sessions on one machine memorize/init at once, serialize the whole
// scan→generate→write→prune pass to avoid interleaved writes producing a mixed index.
// Protocol (ownership-safe, no mistaken-takeover concurrent writers):
//   - Lock = kbDir/.gen-lock directory (mkdir is atomic) holding an owner file with this process's token.
//   - Stale takeover: owner mtime beyond the threshold → renameSync into a unique quarantine
//     name, delete it, then go back to competing on mkdir. rename succeeds for exactly one
//     process per source → two reclaimers can never delete each other's fresh lock.
//   - Pre-write verify: if the owner token is no longer ours, we were taken over as stale
//     mid-run (e.g. a legitimately slow pass) → yield and skip writing; never interleave
//     with the new holder.
//   - Release validates the token: only our own lock is removed; a resurrected old holder
//     cannot delete its successor's lock.
//   - A synchronous script cannot heartbeat; verify-time utimes on the owner file stands in
//     for phase liveness (a full pass is usually <1s; the 60s threshold has ~60x headroom,
//     and even a mistaken takeover is safe because verify yields).
const lockDir = join(kbDir, '.gen-lock');
const ownerFile = join(lockDir, 'owner');
const LOCK_STALE_MS = Number(process.env.LORE_GEN_LOCK_STALE_MS) > 0 ? Number(process.env.LORE_GEN_LOCK_STALE_MS) : 60_000;
const myToken = `${process.pid}:${Math.random().toString(36).slice(2)}`;
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const ownsLock = () => {
	try {
		return readFileSync(ownerFile, 'utf8') === myToken;
	} catch {
		return false;
	}
};
let locked = false;
function releaseLock() {
	if (locked && ownsLock()) rmSync(lockDir, {recursive: true, force: true});
	locked = false;
}
function acquireLock() {
	for (let waits = 0; ; ) {
		try {
			mkdirSync(lockDir);
			writeFileSync(ownerFile, myToken);
			locked = true;
			return;
		} catch (e) {
			if (e.code !== 'EEXIST') throw e;
		}
		let age;
		try {
			// In the tiny window before owner is written, fall back to the lock dir's
			// mtime (freshly created → takes the wait branch)
			age = Date.now() - statSync(existsSync(ownerFile) ? ownerFile : lockDir).mtimeMs;
		} catch {
			continue; // the holder just released; retry immediately
		}
		if (age > LOCK_STALE_MS) {
			// Atomic takeover: rename to a unique quarantine name with pid+timestamp — the
			// winner gets exclusive cleanup rights then competes again; a loser (ENOENT)
			// means another reclaimer quarantined it first, also compete again.
			const quarantine = `${lockDir}.stale-${process.pid}-${Date.now().toString(36)}`;
			try {
				renameSync(lockDir, quarantine);
				rmSync(quarantine, {recursive: true, force: true});
			} catch {}
			continue;
		}
		if (++waits > 3) {
			console.error(`[gen-knowledge-index] another generator holds ${lockDir}; retry shortly (a leftover lock older than ${LOCK_STALE_MS / 1000}s is reclaimed automatically)`);
			process.exit(1);
		}
		sleep(500);
	}
}
if (!check) {
	assertDirInRoot(kbDir, 'docs/ai-knowledge');
	assertDirInRoot(rulesDir, '.claude/rules/knowledge');
	acquireLock();
	if (process.env.LORE_GEN_TEST_HOLD_MS) sleep(Number(process.env.LORE_GEN_TEST_HOLD_MS)); // concurrency regression tests only (test-gen-lock.sh): simulate a slow scan
	process.on('exit', releaseLock);
}

const stripQuotes = (s) => s.replace(/^['"]|['"]$/g, '');
// Strip YAML inline comments (` # …`) from unquoted values. The canonical frontmatter
// template annotates code-anchors inline, and without this the comment text became part of
// the anchor — which then reported as a dead anchor. Whitespace before # is required, so a
// literal '#' inside a path or description survives.
const stripComment = (s) => (/^['"]/.test(s) ? s : s.replace(/\s+#.*$/, '').trim());

function parseFrontmatter(text) {
	if (!text.startsWith('---')) return null;
	const end = text.indexOf('\n---', 3);
	if (end === -1) return null;
	const fm = {};
	let curKey = null;
	for (const raw of text.slice(4, end).split('\n')) {
		if (/^\s*#/.test(raw) || !raw.trim()) continue;
		const arrayItem = raw.match(/^\s+-\s+(.*)$/);
		if (arrayItem && curKey) {
			const item = stripQuotes(stripComment(arrayItem[1].trim()));
			if (item) (fm[curKey] = fm[curKey] || []).push(item);
			continue;
		}
		const kv = raw.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
		if (!kv) continue;
		curKey = kv[1];
		const val = kv[2].trim();
		if (!val) {
			fm[curKey] = fm[curKey] ?? null; // block-array opening line "key:"
		} else if (val.startsWith('[')) {
			fm[curKey] = stripComment(val)
				.replace(/^\[|\]$/g, '')
				.split(',')
				.map((s) => stripQuotes(s.trim()))
				.filter(Boolean);
			curKey = null;
		} else {
			// description is free text and may legitimately contain ' # ' — never comment-strip it
			fm[curKey] = stripQuotes(curKey === 'description' ? val : stripComment(val));
			curKey = null;
		}
	}
	return fm;
}

const problems = [];
// Lint hints: quality signals that are not errors. They surface the write-time causes behind
// the top 'retrieved but ignored' entries measured in practice, so they can be fixed at the
// source instead of during monthly governance. Non-blocking unless --strict.
const lints = [];
const BROAD_DESC = /\b(read (this )?before (changing|touching|modifying|editing)|must[- ]read|always read|read when(ever)? touching|read before any change)\b|必读/i;
const entries = [];
// `name` becomes a rules output filename, so it is validated before use: an unvalidated
// value like `../../../etc/x` would write outside the repo, and two files sharing a name
// would silently overwrite each other's rule.
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;
const seenNames = new Map();
for (const f of readdirSync(kbDir).sort()) {
	// AGENTS.md / CLAUDE.md are the generated write-gate files, not knowledge entries
	if (!f.endsWith('.md') || f === 'INDEX.md' || f === 'AGENTS.md' || f === 'CLAUDE.md' || f.startsWith('_')) continue;
	const p = join(kbDir, f);
	if (statSync(p).isDirectory()) continue;
	const text = readFileSync(p, 'utf8');
	const fm = parseFrontmatter(text);
	if (!fm || !fm.name || !fm.description) {
		problems.push(`${f}: missing frontmatter or required fields name/description`);
		continue;
	}
	if (typeof fm.name !== 'string' || !NAME_RE.test(fm.name)) {
		problems.push(`${f}: invalid name "${fm.name}" — must be kebab-case [a-z0-9-], starting with a letter or digit (it becomes a rules filename)`);
		continue;
	}
	if (seenNames.has(fm.name)) {
		problems.push(`${f}: duplicate name "${fm.name}" (already used by ${seenNames.get(fm.name)}) — names must be unique, one topic per file`);
		continue;
	}
	seenNames.set(fm.name, f);
	// Enum/format validation so `--check` really does mean "frontmatter is legal", which is
	// what the CI template promises. Unknown values are usually typos that silently change
	// how an entry is flagged in the index (or skipped by governance flows).
	for (const [key, allowed] of [
		['status', ['fact', 'hypothesis']],
		['scope', ['repo', 'cross-repo']],
		['promote', ['pending', 'done', 'n/a']],
		['env', ['testing', 'prod', 'all']],
	]) {
		if (fm[key] === undefined || fm[key] === null) problems.push(`${f}: missing required field ${key} (expected one of ${allowed.join(' | ')})`);
		else if (!allowed.includes(fm[key])) problems.push(`${f}: invalid ${key} "${fm[key]}" (expected one of ${allowed.join(' | ')})`);
	}
	if (!/^\d{4}-\d{2}-\d{2}$/.test(fm.updated || '')) problems.push(`${f}: invalid or missing updated "${fm.updated ?? ''}" (expected YYYY-MM-DD)`);
	const anchors = Array.isArray(fm['code-anchors']) ? fm['code-anchors'] : fm['code-anchors'] ? [fm['code-anchors']] : [];
	const localAnchors = [];
	for (const a of anchors) {
		// Cross-repo anchor repo:path (the part before the colon is a sibling repo
		// directory name, distinguishing it from an in-repo relative path); a sibling
		// repo = a same-named directory under the parent dir
		const x = a.match(/^([^/:]+):(.+)$/);
		if (x) {
			const sibRoot = join(repoRoot, '..', x[1]);
			// Sibling locally reachable → validate the path; unreachable (single-repo CI checkout) → skip without error
			if (existsSync(sibRoot) && !existsSync(join(sibRoot, x[2]))) problems.push(`${f}: dead cross-repo code-anchor → ${a}`);
		} else {
			if (!existsSync(join(repoRoot, a))) problems.push(`${f}: dead code-anchor → ${a}`);
			localAnchors.push(a); // only in-repo anchors become rules path-globs
		}
	}
	if (BROAD_DESC.test(fm.description)) lints.push(`${f}: description uses a catch-all phrasing ("read before changing …") — it matches most sessions and gets ignored; narrow it to concrete symptoms / errors / scenarios`);
	if (fm.description.length > 400) lints.push(`${f}: description is ${fm.description.length} chars — likely bundling several topics; split into one entry per symptom family`);
	for (const a of localAnchors) if (a.endsWith('/')) lints.push(`${f}: directory anchor "${a}" pushes this entry on ANY change under it — anchor to the specific file(s) that carry the fact unless the whole tree truly needs it`);
	const lineCount = text.split('\n').length;
	if (lineCount > 180) lints.push(`${f}: ${lineCount} lines — over the 100–200 guideline; consider splitting`);
	entries.push({file: `docs/ai-knowledge/${f}`, fm, anchors, localAnchors});
}
entries.sort((a, b) => a.fm.name.localeCompare(b.fm.name));

// The per-repo config is read by the capture/governance skills, so a malformed file must
// surface here rather than silently reverting them to the default language.
const configPath = join(kbDir, 'lore.json');
let cfg = {};
if (existsSync(configPath)) {
	try {
		cfg = JSON.parse(readFileSync(configPath, 'utf8')) || {};
		if (cfg.language !== undefined && typeof cfg.language !== 'string') problems.push('lore.json: "language" must be a string (a BCP 47 tag such as "en" or "zh-CN")');
		if (cfg.indexMode !== undefined && !['flat', 'grouped', 'auto'].includes(cfg.indexMode)) problems.push('lore.json: "indexMode" must be flat | grouped | auto');
		if (cfg.indexGroupThreshold !== undefined && !(Number.isInteger(cfg.indexGroupThreshold) && cfg.indexGroupThreshold > 0)) problems.push('lore.json: "indexGroupThreshold" must be a positive integer');
		if (cfg.promotionTarget !== undefined && typeof cfg.promotionTarget !== 'string') problems.push('lore.json: "promotionTarget" must be a string naming the team memory layer cross-repo knowledge is promoted to');
	} catch {
		cfg = {};
		problems.push('lore.json: not valid JSON');
	}
}

// ---------- INDEX.md ----------
const indexLines = [
	'<!-- GENERATED by lore (gen-knowledge-index.mjs) — do not hand-edit; change the knowledge files\x27 frontmatter and regenerate -->',
	'# Knowledge index (read on demand — open only what matches)',
	'',
	'> Trust protocol: knowledge is a lead, not the source of truth — verify against the code via each file\x27s code-anchors before key decisions; when knowledge contradicts code, the code wins and the knowledge file gets fixed in passing. Learned a new business fact while finishing a task → invoke lore:memorize (agents without that skill must not write this directory directly; write policy: this directory\x27s AGENTS.md).',
	'',
];
// ---- scaling: flat vs grouped index ----
// INDEX.md is loaded whole every session, so a flat list re-creates the "CLAUDE.md is too big"
// problem once a repo holds dozens of entries. Above a threshold (lore.json indexGroupThreshold,
// default 30; indexMode flat|grouped|auto overrides) the index switches to sections keyed by
// the anchored code area (first two path segments of the first local anchor), with trimmed
// descriptions — the head of a description carries its symptom keywords; the full trigger
// list lives in the file's frontmatter. Path-scoped rules are unaffected either way.
const indexMode = cfg.indexMode || 'auto';
const groupThreshold = cfg.indexGroupThreshold || 30;
const grouped = indexMode === 'grouped' || (indexMode === 'auto' && entries.length > groupThreshold);
const flagsOf = (e) =>
	[e.fm.status === 'hypothesis' ? '⚠ hypothesis' : '', e.fm.scope === 'cross-repo' ? '🔁 cross-repo' : ''].filter(Boolean).join(', ');
const trim = (str, n) => (str.length <= n ? str : str.slice(0, n).replace(/\s+\S*$/, '') + '…');
const groupOf = (e) => {
	const a = e.localAnchors[0];
	if (!a) return e.anchors.length ? 'cross-repo' : 'general';
	const segs = a.replace(/\/+$/, '').split('/');
	const dirSegs = a.endsWith('/') ? segs : segs.slice(0, -1);
	return dirSegs.slice(0, 2).join('/') || 'general';
};
if (!grouped) {
	for (const e of entries) {
		const flags = flagsOf(e);
		indexLines.push(`- **${e.fm.name}**${flags ? ` (${flags})` : ''} — ${e.fm.description} → ${e.file}`);
	}
} else {
	indexLines.push(`> Grouped index (${entries.length} entries, above the ${groupThreshold}-entry threshold): one section per anchored code area; descriptions are trimmed — open the file for the full trigger list.`, '');
	const groups = new Map();
	for (const e of entries) {
		const g = groupOf(e);
		if (!groups.has(g)) groups.set(g, []);
		groups.get(g).push(e);
	}
	const tail = ['cross-repo', 'general'];
	const order = [...groups.keys()].sort((x, y) => (tail.indexOf(x) - tail.indexOf(y)) || x.localeCompare(y));
	for (const g of order) {
		indexLines.push(`## ${g} (${groups.get(g).length})`);
		for (const e of groups.get(g)) {
			const flags = flagsOf(e);
			indexLines.push(`- **${e.fm.name}**${flags ? ` (${flags})` : ''} — ${trim(e.fm.description, 140)} → ${e.file}`);
		}
		indexLines.push('');
	}
	if (indexLines[indexLines.length - 1] === '') indexLines.pop();
}
const indexContent = indexLines.join('\n') + '\n';

// ---------- .claude/rules/knowledge/*.md ----------
const ruleFiles = new Map();
for (const e of entries) {
	if (!e.localAnchors.length) continue;
	const globs = e.localAnchors.map((a) => (a.endsWith('/') ? `${a}**` : a));
	const body =
		[
			'---',
			'paths:',
			...globs.map((g) => `  - "${g}"`),
			'---',
			'',
			'<!-- GENERATED by lore — do not hand-edit -->',
			`> Knowledge exists for this area: read ${e.file} first (${e.fm.description}).`,
			'> Knowledge is a lead, not the source of truth — verify against the code via the file\x27s anchors before key decisions; when it contradicts the code, the code wins and the knowledge file gets fixed.',
		].join('\n') + '\n';
	ruleFiles.set(`${e.fm.name}.md`, body);
}

// ---------- Write-gate files (docs/ai-knowledge/{AGENTS,CLAUDE}.md) ----------
// Emitted as generated artifacts so every lore repo carries an identical, --check-enforced
// write policy. Nested AGENTS.md reaches Codex-style runtimes, nested CLAUDE.md reaches
// Claude Code — both load automatically when an agent touches files in the knowledge dir.
const gateContent =
	[
		'<!-- GENERATED by lore (gen-knowledge-index.mjs) — do not hand-edit; to change the wording, change the generator and regenerate -->',
		'# Write policy for this directory (lore knowledge base)',
		'',
		'This directory is the content layer of the lore knowledge base: **reads are open, writes are gated**.',
		'',
		'- **Read**: anyone / any agent, on demand via the `INDEX.md` index — no tooling required.',
		'- **Write** (create / rewrite / delete files here): only through the lore engine flows — Claude Code\x27s `lore:memorize` / `lore:knowledge-consolidate` / `lore:resolve-merge` / `lore:init` / `lore:set-language` / `lore:harvest`, or the corresponding installed `lore-*` skills on Codex. Those flows carry the rubric, dedupe, scope routing, index rebuild, and capture telemetry; hand-writing bypasses all of it.',
		'- **Agents without those skills must not create or rewrite files here**: learned a business fact worth keeping → put it in the PR description / handoff notes, or tell the user "there is candidate knowledge to capture" and let a lore-equipped session do it.',
		'- The one exception (trust protocol): on finding knowledge that contradicts the code, any agent may make a **minimal correction** — fix only the demonstrably stale facts in the body and refresh the frontmatter `updated` date; no new files, no other frontmatter changes, no full rewrites. In lore-equipped sessions even this goes through `lore:memorize` (it has a built-in correction path) — do not hand-edit.',
		'- **Generated artifacts are never hand-edited**: `INDEX.md`, `.claude/rules/knowledge/*.md`, and this file are produced by `gen-knowledge-index.mjs`; after changing knowledge-file frontmatter, rerun the generator.',
		'- **This policy has an enforcement layer, not just good faith**: in lore-equipped Claude Code sessions a hook intercepts direct edits to this directory — artifacts are denied unconditionally; knowledge files require a write grant that **only the hook itself issues when a lore skill is invoked — bounded uses, cleared at Stop, short-TTL backstop for interrupted turns** (there is no manual grant command). What that guarantees: **at the moment a knowledge file is written, the skill\x27s instructions are necessarily in context** (rubric, dedupe, frontmatter spec, regeneration step all visible) — exactly the piece missing from past incidents.',
		'- **What it cannot guarantee (honest boundary)**: agents hold Bash, and any filesystem-based credential can be forged with a `touch`, so this is not an "unbypassable" security mechanism; writes via Bash likewise skip the hook. Both are backstopped by repo-side CI (the engine\x27s `ci/knowledge-check.yml`: valid frontmatter + live anchors + zero artifact drift) and chased down in code review — deliberate forgery has crossed from "cutting corners" into "willful violation" and is out of this gate\x27s scope by design.',
	].join('\n') + '\n';

const desired = new Map([
	['docs/ai-knowledge/INDEX.md', indexContent],
	['docs/ai-knowledge/AGENTS.md', gateContent],
	['docs/ai-knowledge/CLAUDE.md', gateContent],
]);
for (const [name, content] of ruleFiles) desired.set(`.claude/rules/knowledge/${name}`, content);

// ---------- .gitattributes union entries for generated artifacts ----------
// Owned by the generator, per-entry: a whole-block "skip if the INDEX line exists" check
// (as init used to instruct) never backfills newly introduced artifact lines on already
// onboarded repos — their gate files would fall back to default merge. Write mode appends
// exactly the missing lines; --check reports them as drift.
const GA_COMMENT = '# lore generated artifacts (union-merged where set; rerun the generator to converge; CI --check backstops drift)';
const gaEntries = [
	'docs/ai-knowledge/INDEX.md merge=union linguist-generated=true',
	'docs/ai-knowledge/AGENTS.md merge=union linguist-generated=true',
	'docs/ai-knowledge/CLAUDE.md merge=union linguist-generated=true',
	'.claude/rules/knowledge/*.md merge=union linguist-generated=true',
	// Per-user metrics rollups: generated (linguist), but NOT merge=union — union would
	// corrupt JSON, and per-user files never conflict anyway (each user writes only their own)
	'docs/ai-knowledge/.metrics/*.json linguist-generated=true',
];
const gaPath = join(repoRoot, '.gitattributes');
const gaText = existsSync(gaPath) ? readFileSync(gaPath, 'utf8') : '';
const gaHave = new Set(gaText.split('\n').map((l) => l.trim()));
const gaMissing = gaEntries.filter((e) => !gaHave.has(e));

const orphans = [];
if (existsSync(rulesDir)) {
	for (const f of readdirSync(rulesDir)) {
		if (f.endsWith('.md') && !ruleFiles.has(f)) orphans.push(`.claude/rules/knowledge/${f}`);
	}
}

if (check) {
	const drift = [];
	for (const [rel, content] of desired) {
		const p = join(repoRoot, rel);
		if (!existsSync(p) || readFileSync(p, 'utf8') !== content) drift.push(rel);
	}
	for (const o of orphans) drift.push(`${o} (orphan, must be deleted)`);
	if (gaMissing.length) drift.push(`.gitattributes (missing ${gaMissing.length} generated-artifact union line(s))`);
	for (const x of lints) console.error(`[lint] ${x}`);
	if (strict) problems.push(...lints.map((l) => `(strict) ${l}`));
	if (problems.length || drift.length) {
		for (const x of problems) console.error(`[problem] ${x}`);
		for (const x of drift) console.error(`[drift] ${x} differs from the generated result — run gen-knowledge-index.mjs and commit`);
		process.exit(1);
	}
	console.log(`[gen-knowledge-index] check passed: ${entries.length} knowledge file(s), ${ruleFiles.size} rule(s)${lints.length ? `, ${lints.length} lint hint(s) above (pass --strict to enforce)` : ''}`);
	process.exit(0);
}

// Pre-write ownership verify: taken over as stale mid-run (a legitimately slow pass, etc.)
// → yield and skip writing, never interleave; on success refresh the owner mtime as the
// write-phase liveness signal.
if (!ownsLock()) {
	console.error('[gen-knowledge-index] the lock was reclaimed by another process mid-run; skipping the write to avoid interleaving — rerun');
	process.exit(1);
}
utimesSync(ownerFile, new Date(), new Date());

for (const [rel, content] of desired) {
	safeWrite(join(repoRoot, rel), content, rel);
}
if (gaMissing.length) {
	// Insert right after the last existing lore entry to keep the block together;
	// no lore entry yet → start a new commented block at EOF.
	const lines = gaText ? gaText.split('\n') : [];
	if (lines.length && lines[lines.length - 1] === '') lines.pop();
	let at = -1;
	lines.forEach((l, i) => {
		if (gaEntries.includes(l.trim())) at = i;
	});
	if (at === -1) {
		if (lines.length) lines.push('');
		lines.push(GA_COMMENT);
		at = lines.length - 1;
	}
	lines.splice(at + 1, 0, ...gaMissing);
	safeWrite(gaPath, lines.join('\n') + '\n', '.gitattributes');
}
for (const o of orphans) rmSync(join(repoRoot, o));
for (const x of lints) console.error(`[lint] ${x}`);
for (const x of problems) console.error(`[problem] ${x}`);
console.log(
	`[gen-knowledge-index] generated INDEX.md (${entries.length} entries) + ${ruleFiles.size} rule(s)${orphans.length ? `, pruned ${orphans.length} orphan rule(s)` : ''}${gaMissing.length ? `, backfilled ${gaMissing.length} .gitattributes union line(s)` : ''}`,
);
// Invalid entries were skipped, not silently swallowed: artifacts are written (so the valid
// remainder converges) but the exit code tells the calling flow something needs fixing.
if (problems.length) process.exit(1);
