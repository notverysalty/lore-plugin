#!/bin/bash
# lore Stop gate: deterministically decide "did this session do substantial work",
# and only then let the main session evaluate whether to invoke memorize.
# First layer of the two-layer gate (zero tokens); the second layer is the main
# session LLM's semantic judgment.
# Cross-runtime: pass codex / --format=codex to use the Codex state dir and skill names.
#                Both runtimes take the SAME Stop output shape — {"decision":"block","reason"}
#                — which on both means "continue, injecting reason as the next user prompt"
#                (per the Codex hooks docs as of codex-cli 0.144.x; the older
#                {"continue":false,"stopReason"} shape means STOP there and must not be used).
# Principle: any anomaly exits silently (exit 0, no output); never block the user's session.
set -u

FORMAT=claude
case "${1:-}" in codex | --codex | --format=codex) FORMAT=codex ;; esac

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# 1. Loop guard: Claude Code marks the second stop with stop_hook_active; Codex
#    has no such field and relies on the self-maintained cooldown below.
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0

# 2. Never fire inside subagents
[ -n "$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)" ] && exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
{ [ -z "$cwd" ] || [ -z "$sid" ]; } && exit 0

# 3. Opt-in: repos without a knowledge base (docs/ai-knowledge/) get total silence.
#    The payload cwd may be a SUBDIRECTORY of the repo (agents are often started in src/),
#    so walk up to the nearest ancestor that has the knowledge dir instead of testing cwd
#    alone — otherwise lore silently does nothing for that session.
root=""
probe="$cwd"
while [ -n "$probe" ] && [ "$probe" != "/" ]; do
	if [ -d "$probe/docs/ai-knowledge" ]; then
		root="$probe"
		break
	fi
	probe=$(dirname "$probe")
done
[ -n "$root" ] || exit 0

# 4. State dir (the two runtimes are kept separate)
if [ "$FORMAT" = codex ]; then
	data_dir="${LORE_DATA_DIR:-$HOME/.codex/lore-data}"
else
	# Not CLAUDE_PLUGIN_DATA: that dir is deleted on uninstall (metrics were lost
	# to a reinstall once); use a stable dir instead. LORE_DATA_DIR is for tests.
	data_dir="${LORE_DATA_DIR:-$HOME/.claude/plugins/data/lore}"
fi
mkdir -p "$data_dir/sessions" 2>/dev/null || exit 0
state="$data_dir/sessions/$sid"

# 5. Cooldown: at most 2 evaluations per session (Codex's main loop guard)
count=$(cat "$state.count" 2>/dev/null | tr -dc '0-9')
count=${count:-0}
[ "$count" -ge 2 ] && exit 0

# 6. Signal A: cumulative changed lines against the session's starting HEAD.
#    Not the worktree diff — staged/committed-per-phase workflows leave a clean
#    worktree at Stop and would hide real work.
base=$(cat "$state.head" 2>/dev/null)
[ -z "$base" ] && base=$(git -C "$root" --no-optional-locks rev-parse HEAD 2>/dev/null)
changed=0
if [ -n "$base" ]; then
	changed=$(git -C "$root" --no-optional-locks diff "$base" --shortstat 2>/dev/null |
		grep -oE '[0-9]+ (insertion|deletion)' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
	changed=${changed:-0}
	# Knowledge-only diffs don't count as substantial work (prevents memorize's
	# own writes from re-triggering the gate)
	if [ "$changed" -ge 10 ]; then
		non_knowledge=$(git -C "$root" --no-optional-locks diff "$base" --name-only 2>/dev/null | grep -cv '^docs/ai-knowledge/')
		[ "${non_knowledge:-0}" -eq 0 ] && changed=0
	fi
fi

# 6b. Untracked files count as work too: a session that creates an entirely new module has
#     nothing in `git diff` and would otherwise skip the capture evaluation completely.
#     Bounded to the first 200 untracked paths so a huge unignored tree cannot slow Stop.
ulines=$(git -C "$root" --no-optional-locks ls-files --others --exclude-standard -z 2>/dev/null |
	tr '\0' '\n' | grep -v '^docs/ai-knowledge/' | head -200 |
	while IFS= read -r rel; do
		[ -n "$rel" ] && [ -f "$root/$rel" ] && wc -l < "$root/$rel" 2>/dev/null
	done | awk '{s+=$1} END {print s+0}')
ulines=${ulines:-0}
changed=$((changed + ulines))

# 7. Signal B: long research sessions — no diff but many real user turns.
#    Claude Code transcripts are jsonl; other formats parse to turns=0 and the
#    gate degrades to signal A only, which is acceptable.
turns=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
	turns=$(grep '"type":"user"' "$transcript" 2>/dev/null | grep -vc 'tool_result')
	turns=${turns:-0}
fi

[ "$changed" -lt 10 ] && [ "$turns" -lt 8 ] && exit 0

# 8. Fingerprint dedupe: the same batch of changes / turn window evaluates once
fp_diff=$(git -C "$root" --no-optional-locks diff "$base" 2>/dev/null | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -d' ' -f1)
fp="${fp_diff:-none}-u$ulines-t$((turns / 8))"
[ "$(cat "$state.fp" 2>/dev/null)" = "$fp" ] && exit 0

printf '%s' "$fp" > "$state.fp" 2>/dev/null
printf '%s' "$((count + 1))" > "$state.count" 2>/dev/null

# Telemetry: record the gate firing (fire-rate / capture-conversion metrics;
# silent on failure, never blocks the main flow).
# jq --arg serialization: repo names / sids containing quotes, backslashes, or
# control characters would corrupt the JSONL line under printf interpolation.
jq -nc --arg repo "$(basename "$root")" --arg sid "$sid" --arg fmt "$FORMAT" \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
	'{event:"gate_fire", repo:$repo, session:$sid, format:$fmt, ts:$ts}' >> "$data_dir/metrics.jsonl" 2>/dev/null

# 9. Feedback prep: the lore knowledge files loaded this session (the LLM judges
#    each used/ignored/contradicted at wrap-up, upgrading load-COUNT metrics into
#    load-effectiveness + silent-rot candidates). Only demanded when something was
#    actually loaded — sessions that never touched knowledge carry zero burden.
#    record-feedback.sh / record-write.sh sit next to this script (Claude Code:
#    the plugin's scripts/; Codex: ~/.codex/lore/scripts/).
#    List items carry a kb_repo: prefix (owning repo) which the LLM echoes back,
#    so stats can aggregate per owning repo (bare legacy filenames stay compatible).
fb="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/record-feedback.sh"
rw="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/record-write.sh"
fb_args=""
[ "$FORMAT" = codex ] && fb_args=" --format=codex"
loaded=""
[ -f "$data_dir/metrics.jsonl" ] && loaded=$(jq -r --arg s "$sid" \
	'select(.event=="kb_load" and .session==$s)|if .kb_repo then "\(.kb_repo):\(.file)" else .file end' \
	"$data_dir/metrics.jsonl" 2>/dev/null | sort -u | paste -sd, - 2>/dev/null)

fb_block=""
stale_line=""
if [ -n "$loaded" ]; then
	fb_block='● Knowledge feedback: this session loaded lore knowledge [__LOADED__]. Judge each one and run one command per file (copy the file argument verbatim from the list, including the repo prefix) — used = it shaped your conclusion or changes; ignored = loaded but unused; contradicted = it conflicts with what you actually saw in the code (likely stale):\n  \"__FB__\"__ARGS__ <verdict> <repo:filename.md> \"__SID__\"\n'
	stale_line='\n\n⚠️ Possibly stale: <knowledge files judged contradicted above; delete this line if none>'
fi

# 10. Inject the instruction. TEMPLATE is the single source of truth for the reason text
#     (literal \n escapes, expanded below); both output formats reuse it.
#     Skill name per runtime: Claude Code uses the plugin namespace lore:memorize;
#     Codex installs lore-memorize (see codex/install.sh)
memo_cmd='lore:memorize'
[ "$FORMAT" = codex ] && memo_cmd='lore-memorize'
TEMPLATE='[lore wrap-up check] This session did substantial work.\n'"$fb_block"'● Capture check: did you learn any facts you cannot derive from the code (cross-repo conventions, implicit rules, pitfalls with causes, anti-knowledge)? Yes → invoke __MEMO__ to capture it; keep execution lean, no long narration (the write telemetry is handled inside the memorize flow). No → do not force it, but record the evaluation once (feeds the fire→capture conversion metric):\n  \"__RW__\"__ARGS__ nothing_to_save \"\" \"__SID__\"\n● Wrap-up card: whether or not anything was captured, the VERY END of this reply must print (the status and next step the user cares about, at the very bottom, preceded by ---). Formatting: a blank line between the items; multi-point items get indented sub-lists (①②③/-) on separate lines, never squeezed into one; keep each item'"'"'s first sentence crisp:\n✅ Done: <one sentence; one line per item if several>\n\n⏭️ Next: <one sentence; ①②③ each on its own indented line if several>\n\n🧠 lore: <captured N file(s), one filename per line / nothing to save>'"$stale_line"'\nQuality over quantity — never force a capture.'
# Order matters: expand the \n escapes in the TEMPLATE first (it holds no runtime data, so
# %b cannot misread a backslash that came from a path or a session id), then substitute the
# runtime values with plain parameter expansion (no escape interpretation), then let jq do
# the JSON encoding. Hand-built JSON used to break here whenever a value — or the prose
# itself — contained a double quote or backslash.
REASON=$(printf '%b' "$TEMPLATE")
REASON=${REASON//__MEMO__/$memo_cmd}
REASON=${REASON//__LOADED__/$loaded}
REASON=${REASON//__FB__/$fb}
REASON=${REASON//__RW__/$rw}
REASON=${REASON//__ARGS__/$fb_args}
REASON=${REASON//__SID__/$sid}

# One shape for both runtimes — see the header note on the Codex Stop contract.
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
