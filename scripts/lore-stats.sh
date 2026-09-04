#!/bin/bash
# lore metrics summary: reads metrics.jsonl + scans the local knowledge inventory, printing
#   the capture funnel / fire & load distributions / feedback trend / per-file effectiveness
#   (polish candidates) / contradiction follow-up / inventory (status, pending, cross-repo
#   anchors, never-loaded, time-to-first-use).
# Usage: bash lore-stats.sh [codex] [--since=YYYY-MM-DD]
#        bash lore-stats.sh export-summary [repo-root]   write this machine's per-user metrics
#          rollup for one repo to <repo>/docs/ai-knowledge/.metrics/<user>.json — a small,
#          privacy-safe counts file (no session ids, no timelines) that rides normal PRs, so
#          teammates' stats runs see team-wide usage without any sync infrastructure.
#   --since windows the event metrics only; the inventory scan and "never loaded" always use
#   full history + current file state.
# macOS bash 3.2 compatible: no associative arrays (aggregation via jq/awk), awk -v args
#   instead of interpolating into program strings.
set -u

MODE=claude
SINCE=""
EXPORT=0
EXPORT_ROOT=""
for arg in "$@"; do
	case "$arg" in
		codex | --codex) MODE=codex ;;
		--since=*) SINCE="${arg#--since=}" ;;
		export-summary) EXPORT=1 ;;
		--*) ;;
		*) [ "$EXPORT" = 1 ] && [ -z "$EXPORT_ROOT" ] && EXPORT_ROOT="$arg" ;;
	esac
done
if [ "$EXPORT" = 1 ]; then
	if [ -z "$EXPORT_ROOT" ]; then
		# default: walk up from PWD to the nearest onboarded repo (same rule as the hooks)
		probe="$PWD"
		while [ -n "$probe" ] && [ "$probe" != "/" ]; do
			if [ -d "$probe/docs/ai-knowledge" ]; then
				EXPORT_ROOT="$probe"
				break
			fi
			probe=$(dirname "$probe")
		done
		[ -n "$EXPORT_ROOT" ] || { echo "export-summary: no onboarded repo found at or above $PWD"; exit 1; }
	fi
	# Canonicalize (an explicit "." would otherwise become the repo name) and require an
	# onboarded repo — never create .metrics/ in an arbitrary directory
	EXPORT_ROOT=$(cd "$EXPORT_ROOT" 2>/dev/null && pwd -P) || { echo "export-summary: cannot resolve the repo root"; exit 1; }
	[ -d "$EXPORT_ROOT/docs/ai-knowledge" ] || { echo "export-summary: $EXPORT_ROOT is not onboarded (no docs/ai-knowledge/)"; exit 1; }
fi

if [ -n "${LORE_DATA_DIR:-}" ]; then
	# Explicit override wins in every mode (same convention as all the other scripts;
	# also what makes the whole report testable)
	files=()
	[ -f "$LORE_DATA_DIR/metrics.jsonl" ] && files+=("$LORE_DATA_DIR/metrics.jsonl")
	label="$LORE_DATA_DIR/metrics.jsonl"
elif [ "$MODE" = codex ]; then
	files=()
	mc="$HOME/.codex/lore-data/metrics.jsonl"
	[ -f "$mc" ] && files+=("$mc")
	label="$HOME/.codex/lore-data/metrics.jsonl"
else
	# lore (Claude Code) writes metrics under ~/.claude/plugins/data/lore* (the suffix can
	# vary with the marketplace name). Never trust $CLAUDE_PLUGIN_DATA — the harness sets it
	# to the CALLING plugin's data dir, not lore's; glob all lore* data dirs instead.
	files=()
	for d in "$HOME"/.claude/plugins/data/lore*; do
		[ -f "$d/metrics.jsonl" ] && files+=("$d/metrics.jsonl")
	done
	label="$HOME/.claude/plugins/data/lore*/metrics.jsonl"
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
# A fresh install has no metrics file yet. Do NOT exit here: the inventory scan below needs
# no event data and is exactly what a new user wants to see (what knowledge exists at all).
# The event sections degrade to zeros on their own.
if [ "${#files[@]}" -eq 0 ]; then
	echo "No event metrics yet ($label does not exist; events appear once lore runs a session in an onboarded repo)."
	echo "Showing the inventory scan only."
	echo
fi

# Event-key normalization: owning-repo/filename. kb_repo wins when present (newer
# track-load/record-write data); feedback files may carry a "repo:" prefix (newer gate
# loaded-list format); otherwise fall back to the session repo (legacy data).
# nrepo: worktree stream merging — look the repo name up in $wtmap first (authoritative,
# from live worktrees' .git files), then fall back to a "main-repo-name-" prefix match
# (covers streams from since-deleted worktree dirs), else keep as-is.
JQDEF='def nrepo($r):
	(($r // "?") | tostring) as $x
	| if ($mains | index($x)) != null then $x
	  else ($wtmap[$x] // (first($mains[] | . as $m | select($x | startswith($m + "-"))) // $x))
	  end;
def kbkey:
	(if ((.file // "") | contains(":")) then (.file | split(":")) else null end) as $sp
	| nrepo((.kb_repo // (if $sp then $sp[0] else .repo end)))
	  + "/" + (if $sp then $sp[1] else (.file // "?") end);'

tmp=$(mktemp) tmp_all=$(mktemp) inv_tsv=$(mktemp) loaded_keys=$(mktemp) wt_tsv=$(mktemp) team_tsv=$(mktemp)
trap 'rm -f "$tmp" "$tmp_all" "$inv_tsv" "$loaded_keys" "$wt_tsv" "$team_tsv"' EXIT

# Guarded: `cat` with an empty argument list would read stdin and hang the command
[ "${#files[@]}" -gt 0 ] && cat "${files[@]}" 2>/dev/null > "$tmp_all"
if [ -n "$SINCE" ]; then
	jq -c --arg s "$SINCE" 'select(((.ts // "9999") | .[0:10]) >= $s)' "$tmp_all" 2>/dev/null > "$tmp"
else
	cp "$tmp_all" "$tmp"
fi

# Last-14-days boundary (macOS / GNU date, both spellings; if both fail the trend section
# degrades to cumulative-only)
d14=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d 2>/dev/null)

# ---------- inventory scan (build the TSV first: both the contradiction follow-up and the
#            inventory section need it; metrics are a stream without a denominator) ----------
# Discovery: the current dir + siblings + subdirectories containing docs/ai-knowledge/
# (works from a business repo or an umbrella dir; includes hidden dirs — .wt-* style
# worktrees are identified by git semantics, not naming conventions).
# Worktree test: .git is a FILE whose gitdir points into */.git/worktrees/* → a branch copy
# of a main clone:
#   excluded from the inventory (otherwise each knowledge file is counted once per worktree
#   and pending/never-loaded fill up with ghosts), and its name is mapped to the main repo so
#   event streams (fires/loads/feedback/writes) merge into the main repo's keys.
wt_skipped=0
scan_roots=$(
	{
		printf '%s\n' "$PWD"
		for d in "$PWD"/../*/ "$PWD"/../.[!.]*/ "$PWD"/*/ "$PWD"/.[!.]*/; do printf '%s\n' "${d%/}"; done
	} 2>/dev/null | while IFS= read -r r; do
		[ -d "$r" ] && (cd "$r" 2>/dev/null && pwd)
	done | sort -u
)
inv_roots=""
while IFS= read -r root; do
	[ -n "$root" ] || continue
	if [ -f "$root/.git" ]; then
		gd=$(sed -n 's/^gitdir: *//p' "$root/.git" 2>/dev/null)
		case "$gd" in
		*/.git/worktrees/*)
			printf '%s\t%s\n' "$(basename "$root")" "$(basename "${gd%/.git/worktrees/*}")" >>"$wt_tsv"
			[ -d "$root/docs/ai-knowledge" ] && wt_skipped=$((wt_skipped + 1))
			continue
			;;
		esac
	fi
	[ -d "$root/docs/ai-knowledge" ] && inv_roots="${inv_roots}${root}
"
done <<-EOF
$scan_roots
EOF
if [ -n "$inv_roots" ]; then
	while IFS= read -r root; do
		[ -n "$root" ] || continue
		repo=$(basename "$root")
		for f in "$root"/docs/ai-knowledge/*.md; do
			[ -f "$f" ] || continue
			fname=$(basename "$f")
			# INDEX/AGENTS/CLAUDE are generated artifacts (index / write policy), not knowledge
			case "$fname" in INDEX.md | AGENTS.md | CLAUDE.md) continue ;; esac
			# Extract frontmatter scalars + whether code-anchors contains a cross-repo anchor
			# ("repo:path" list items, excluding comments and URLs)
			awk -v repo="$repo" -v file="$fname" -v root="$root" '
				BEGIN { fs=0; st=""; pr=""; up=""; sc=""; cross=0; inA=0; anchors="" }
				/^---[[:space:]]*$/ { fs++; if (fs==2) exit; next }
				fs==1 {
					if ($0 ~ /^[A-Za-z-]+:/) inA=0
					if ($0 ~ /^code-anchors:/) { inA=1 }
					else if ($0 ~ /^status:/)  { st=$2; gsub(/["\047]/, "", st) }
					else if ($0 ~ /^promote:/) { pr=$2; gsub(/["\047]/, "", pr) }
					else if ($0 ~ /^updated:/) { up=$2; gsub(/["\047]/, "", up) }
					else if ($0 ~ /^scope:/)   { sc=$2; gsub(/["\047]/, "", sc) }
					else if (inA && $0 ~ /^[[:space:]]*-[[:space:]]/) {
						item=$0
						sub(/^[[:space:]]*-[[:space:]]*/, "", item)
						sub(/[[:space:]]*#.*$/, "", item)
						if (item ~ /^[A-Za-z0-9._-]+:/ && item !~ /^https?:/) cross=1
						else if (item != "") anchors = (anchors == "" ? item : anchors "|" item)
					}
				}
				END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", repo, file, st, pr, up, sc, cross, anchors, root }
			' "$f" >> "$inv_tsv"
		done
	done <<-EOF
	$inv_roots
	EOF
fi

# Normalization args (every jq call using nrepo/kbkey must carry JQARGS):
# wtmap = worktree name → main repo name; mains = live main-repo names sorted longest-first
# (prefix fallback prefers the longest match, avoiding mis-mapping)
# Built with jq, not hand-printed: a directory name containing a quote or backslash would
# otherwise emit invalid JSON and break every --argjson call downstream.
WTMAP_JSON=$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")) | map(select(length == 2)) | map({(.[0]): .[1]}) | add // {}' "$wt_tsv")
MAINS_JSON=$(printf '%s' "$inv_roots" | awk 'NF' | while IFS= read -r p; do basename "$p"; done |
	jq -R -s -c 'split("\n") | map(select(length > 0)) | sort_by(-length)')
JQARGS=(--argjson wtmap "$WTMAP_JSON" --argjson mains "$MAINS_JSON")

# ---------- export-summary: write this machine's per-user rollup into the repo ----------
# The rollup is the team-metrics carrier: local metrics never leave the machine, but these
# counts ride normal PRs, and every stats run aggregates all committed rollups — team-wide
# visibility with zero sync infrastructure. Worktree events merge into the main repo via
# nrepo, so exporting from a worktree attributes correctly.
if [ "$EXPORT" = 1 ]; then
	user="${LORE_METRICS_USER:-$(git -C "$EXPORT_ROOT" config user.name 2>/dev/null)}"
	user="${user:-$(whoami 2>/dev/null)}"
	[ -n "$user" ] || { echo "export-summary: cannot determine a user name (set LORE_METRICS_USER)"; exit 1; }
	slug=$(printf '%s' "$user" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-*$//;s/^-*//')
	[ -n "$slug" ] || slug=user
	case "$slug" in .*) slug="u$slug" ;; esac   # a leading dot would hide the file from the aggregation glob
	cutoff=$(date -v-90d +%Y-%m-%d 2>/dev/null || date -d '90 days ago' +%Y-%m-%d 2>/dev/null)
	today=$(date +%Y-%m-%d)
	out_dir="$EXPORT_ROOT/docs/ai-knowledge/.metrics"
	mkdir -p "$out_dir" || exit 1
	# Containment + no-symlink: an onboarded-looking repo must not redirect this write outside
	# itself via a symlinked .metrics dir or target file
	out_real=$(cd "$out_dir" 2>/dev/null && pwd -P) || exit 1
	case "$out_real" in
		"$EXPORT_ROOT/docs/ai-knowledge/.metrics") ;;
		*) echo "export-summary: .metrics resolves outside the repo ($out_real) — refusing"; exit 1 ;;
	esac
	[ -L "$out_dir/$slug.json" ] && { echo "export-summary: target rollup is a symlink — refusing"; exit 1; }
	# Repo identity goes through nrepo, so exporting from a worktree attributes to the main
	# repo (the raw basename would never match the normalized event keys → empty rollup)
	rollup_tmp=$(mktemp "$out_dir/.tmp.XXXXXX") || exit 1
	if ! jq -s "${JQARGS[@]}" --arg rawrepo "$(basename "$EXPORT_ROOT")" --arg user "$user" --arg cutoff "${cutoff:-0000-00-00}" --arg today "$today" "$JQDEF"'
		(nrepo($rawrepo)) as $repo
		| [.[] | select(((.ts // "") | .[0:10]) >= $cutoff)] as $w
		| [$w[] | select(.event == "kb_load" or .event == "kb_feedback" or (.event == "kb_write" and .verdict == "written"))
			| . + {k: kbkey} | select(.k | startswith($repo + "/"))
			| . + {f: (.k | ltrimstr($repo + "/"))}] as $ev
		| {user: $user, repo: $repo, updated: $today, window_days: 90,
		   gate: {
		     fires: ([$w[] | select(.event == "gate_fire") | select(nrepo(.repo) == $repo)] | length),
		     nothing_to_save: ([$w[] | select(.event == "kb_write" and .verdict == "nothing_to_save") | select(nrepo(.kb_repo // .repo) == $repo)] | length)
		   },
		   files: ($ev | group_by(.f) | map({key: .[0].f, value: {
		     loads: (map(select(.event == "kb_load")) | length),
		     used: (map(select(.event == "kb_feedback" and .verdict == "used")) | length),
		     ignored: (map(select(.event == "kb_feedback" and .verdict == "ignored")) | length),
		     contradicted: (map(select(.event == "kb_feedback" and .verdict == "contradicted")) | length),
		     written: (map(select(.event == "kb_write")) | length)
		   }}) | from_entries)}
	' "$tmp_all" > "$rollup_tmp"; then
		rm -f "$rollup_tmp"
		echo "export-summary: failed to build the rollup"
		exit 1
	fi
	mv "$rollup_tmp" "$out_dir/$slug.json" || { rm -f "$rollup_tmp"; exit 1; }
	echo "[lore-stats] wrote $out_dir/$slug.json (user $user, ${cutoff:-∞}..$today) — commit it with your normal PR"
	exit 0
fi

# ---------- output ----------
fires=$(grep -c '"gate_fire"' "$tmp")
loads=$(grep -c '"kb_load"' "$tmp")
fbs=$(grep -c '"kb_feedback"' "$tmp")
writes=$(grep -c '"kb_write"' "$tmp")

echo "=== lore metrics (${#files[@]} data file(s)${SINCE:+, since $SINCE}) ==="
# bash 3.2 + set -u: expanding an empty array is an unbound-variable error — guard it
[ "${#files[@]}" -gt 0 ] && printf '  %s\n' "${files[@]}"
echo "gate fires: ${fires}   knowledge loads: ${loads}   feedback: ${fbs}   capture records: ${writes}"
echo
echo "-- capture funnel (did gate_fire lead to knowledge? no record = gate ignored, or a fire predating the write telemetry) --"
jq -s -r '
	([.[] | select(.event=="gate_fire") | .session] | unique) as $g
	| ([.[] | select(.event=="kb_write" and .session != "unknown") | .session] | unique) as $ws
	| ($g - ($g - $ws) | length) as $resp
	| ([.[] | select(.event=="kb_write" and .verdict=="written")] | length) as $wn
	| ([.[] | select(.event=="kb_write" and .verdict=="nothing_to_save")] | length) as $ns
	| ([.[] | select(.event=="kb_write" and .session=="unknown")] | length) as $unk
	| ("sessions with fires: \($g|length) → with capture records: \($resp)"
	   + (if ($g|length) > 0 then " (response rate \(100*$resp/($g|length) | round)%)" else "" end)),
	  ("written (real writes): \($wn)   nothing_to_save (evaluated, nothing qualified): \($ns)"
	   + (if $unk > 0 then "   records without a session: \($unk)" else "" end)),
	  (if ($g|length) > $resp then "sessions without records: \(($g|length) - $resp) (fires predating the write telemetry have none — expected)" else empty end)
' "$tmp" 2>/dev/null
echo
echo "-- fires by repo (where capture opportunities come from; worktrees merged into main repos) --"
jq -r "${JQARGS[@]}" "$JQDEF"'select(.event=="gate_fire") | nrepo(.repo)' "$tmp" 2>/dev/null | sort | uniq -c | sort -rn | head
echo "-- top loaded knowledge (most read = most hit; aggregated by owning repo, worktrees merged) --"
jq -r "${JQARGS[@]}" "$JQDEF"'select(.event=="kb_load") | kbkey' "$tmp" 2>/dev/null | sort | uniq -c | sort -rn | head
echo "-- load reasons (path_glob_match = rules push hit; session_start = always-on index) --"
jq -r 'select(.event=="kb_load") | .reason' "$tmp" 2>/dev/null | sort | uniq -c | sort -rn
echo
echo "-- read effectiveness (feedback: after loading, was it actually useful / still true?) --"
if [ "$fbs" -gt 0 ]; then
	used=$(jq -r 'select(.event=="kb_feedback") | .verdict' "$tmp" 2>/dev/null | grep -c '^used$')
	ignored=$(jq -r 'select(.event=="kb_feedback") | .verdict' "$tmp" 2>/dev/null | grep -c '^ignored$')
	contra=$(jq -r 'select(.event=="kb_feedback") | .verdict' "$tmp" 2>/dev/null | grep -c '^contradicted$')
	echo "used: ${used}   ignored (loaded, unused): ${ignored}   contradicted (conflicts with code): ${contra}"
	denom=$((used + ignored))
	if [ "$denom" -gt 0 ]; then
		# awk -v args, no interpolation into the program string — macOS bash 3.2 mangles
		# nested quotes inside "…$(awk "…\"…\"…")…" (inner quotes collapse and brace
		# expansion splits {printf …, …} into two invalid programs)
		rate=$(awk -v u="$used" -v d="$denom" 'BEGIN{printf "%.0f", u*100/d}' 2>/dev/null)
		echo "hit rate: ${rate}% (used/(used+ignored); low = knowledge gets retrieved but doesn't help — polish descriptions/bodies)"
	fi

	if [ -n "$d14" ]; then
		echo
		echo "-- feedback trend (last 14 days vs before; cumulative numbers hide slippage — fresh feedback reflects now) --"
		jq -s -r --arg c "$d14" '
			def line($lab; $xs):
				($xs | map(select(.verdict=="used")) | length) as $u
				| ($xs | map(select(.verdict=="ignored")) | length) as $i
				| "\($lab): used \($u) / ignored \($i)"
				  + (if ($u+$i) > 0 then " (hit rate \(100*$u/($u+$i) | round)%)" else " (no data)" end);
			[.[] | select(.event=="kb_feedback")] as $fb
			| line("before      "; [$fb[] | select(.ts[0:10] < $c)]),
			  line("last 14 days"; [$fb[] | select(.ts[0:10] >= $c)])
		' "$tmp" 2>/dev/null
		echo "daily detail (last 14 days):"
		jq -r --arg c "$d14" 'select(.event=="kb_feedback" and .ts[0:10] >= $c) | "\(.ts[0:10]) \(.verdict)"' "$tmp" 2>/dev/null |
			awk '{ d[$1]=1; c[$1" "$2]++ }
				END { for (k in d) printf "  %s  used %d / ignored %d / contradicted %d\n", k, c[k" used"], c[k" ignored"], c[k" contradicted"] }' |
			sort
	fi

	echo
	echo "-- polish candidates (high-load, low-hit: ignored >= 2 and > used — retrieved but not helping; each with a fix prescription; INDEX is generated, not listed) --"
	jq -s -r "${JQARGS[@]}" "$JQDEF"'
		[.[] | select(.event=="kb_feedback") | select((kbkey | endswith("/INDEX.md")) | not)]
		| group_by(kbkey)
		| map((.[0] | kbkey) as $k
			| (map(select(.verdict=="used")) | length) as $u
			| (map(select(.verdict=="ignored")) | length) as $i
			| select($i >= 2 and $i > $u)
			| { k: $k, u: $u, i: $i })
		| sort_by(-.i)
		| if length == 0 then "  (none)" else .[] | "  ignored \(.i) / used \(.u)   \(.k)" end
	' "$tmp" 2>/dev/null | while IFS= read -r line; do
		printf '%s\n' "$line"
		case "$line" in "  (none)") continue ;; esac
		# Prescription: cross the ignored signal with the write-time smells that cause it (the
		# same checks gen --check lints), so governance gets a concrete action, not just a number
		key=${line##* }
		repo=${key%%/*}
		file=${key#*/}
		row=$(awk -F'\t' -v r="$repo" -v f="$file" '$1 == r && $2 == f { print; exit }' "$inv_tsv" 2>/dev/null)
		[ -n "$row" ] || continue
		anchors=$(printf '%s' "$row" | cut -f8)
		kpath="$(printf '%s' "$row" | cut -f9)/docs/ai-knowledge/$file"
		rx=""
		case "$anchors" in */\|* | */) rx="${rx}directory anchor → narrow to the specific file(s) carrying the fact; " ;; esac
		desc=$(awk '/^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }' "$kpath" 2>/dev/null)
		printf '%s' "$desc" | grep -qiE 'read (this )?before (changing|touching|modifying|editing)|must[- ]read|always read|必读' && rx="${rx}catch-all description → rewrite to concrete symptoms/errors; "
		[ "${#desc}" -gt 400 ] && rx="${rx}description bundles several topics → split into one entry per symptom family; "
		klines=$(wc -l < "$kpath" 2>/dev/null | tr -d ' ')
		[ "${klines:-0}" -gt 180 ] && rx="${rx}${klines} lines → split; "
		[ -z "$rx" ] && rx="no structural smell — check whether the pushing sessions really concern this topic (a hot anchor file pushes on unrelated edits) or whether the body duplicates CLAUDE.md"
		printf '      ↳ %s\n' "${rx% }"
	done

	if [ "$contra" -gt 0 ]; then
		echo
		echo "-- ⚠️ contradiction follow-up (judged contradicting the code = likely silently stale) + loop state --"
		# Per contradicted key: a later used = re-used; else file updated on/after the judgment
		# date = updated, awaiting re-verification; else still unresolved
		jq -s -r "${JQARGS[@]}" "$JQDEF"'
			[.[] | select(.event=="kb_feedback" and .verdict=="contradicted")]
			| group_by(kbkey)
			| map((.[0] | kbkey) + "\t" + (map(.ts) | max) + "\t" + (length | tostring))
			| .[]
		' "$tmp" 2>/dev/null | while IFS=$'\t' read -r key cts n; do
			[ -n "$key" ] || continue
			reused=$(jq -r "${JQARGS[@]}" --arg k "$key" --arg t "$cts" "$JQDEF"'select(.event=="kb_feedback" and .verdict=="used" and kbkey == $k and .ts > $t) | 1' "$tmp_all" 2>/dev/null | head -1)
			if [ -n "$reused" ]; then
				state="✔ re-used (a used verdict followed the contradiction)"
			else
				up=$(awk -F'\t' -v k="$key" '$1 "/" $2 == k { print $5; exit }' "$inv_tsv" 2>/dev/null)
				# >= not >: the contradiction and its fix usually land in the same session (same
				# day; updated has day granularity) — strict > would misread a same-day fix as
				# still unresolved
				if [ -n "$up" ] && { [ "$up" \> "${cts:0:10}" ] || [ "$up" = "${cts:0:10}" ]; }; then
					state="◐ updated, awaiting re-verification (file updated $up, not before the judgment)"
				else
					state="✖ still unresolved (neither fixed nor re-used → top priority for consolidate)"
				fi
			fi
			echo "  ${key} (contradicted ×${n}, latest ${cts:0:10}) $state"
		done
	fi
else
	echo "(no feedback yet; the gate only asks for verdicts in sessions that loaded knowledge — run a few such sessions)"
fi

echo
if [ -z "$inv_roots" ]; then
	echo "-- inventory: no docs/ai-knowledge found in this dir or its siblings/children — skipped (run from a business repo or umbrella dir) --"
else
	inv_repos=$(cut -f1 "$inv_tsv" | sort -u | grep -c .)
	inv_files=$(grep -c . "$inv_tsv")
	cross_n=$(awk -F'\t' '$7==1' "$inv_tsv" | grep -c .)
	pend_n=$(awk -F'\t' '$4=="pending"' "$inv_tsv" | grep -c .)
	echo "-- inventory (${inv_repos} repo(s) / ${inv_files} file(s) locally reachable, excl. generated files/archive; ${wt_skipped} worktree copies excluded; the denominator metrics lack) --"
	echo "status distribution: $(cut -f3 "$inv_tsv" | awk '{ print ($0=="" ? "(no status)" : $0) }' | sort | uniq -c | sort -rn | awk '{ printf "%s%s %s", (NR>1 ? " / " : ""), $2, $1 } END { print "" }')"
	echo "cross-repo anchors: ${cross_n} file(s) (repo:path anchors)"
	if [ "$pend_n" -gt 0 ]; then
		echo "promote:pending backlog: ${pend_n} file(s) (harvesting is consolidate's input; the older the updated, the more overdue):"
		awk -F'\t' '$4=="pending" { printf "  %s/%s (updated %s)\n", $1, $2, ($5=="" ? "?" : $5) }' "$inv_tsv" | sort
	else
		echo "promote:pending backlog: 0"
	fi

	# ---------- team rollups: per-user counts committed into each repo by export-summary ----------
	# The event sections above are this machine's stream only; the rollups extend coverage to
	# everyone who committed one. They also feed the "never loaded" exclusion below, so a file
	# a teammate reads daily is not misreported as a retirement candidate.
	# Defensive parse: rollups are repo content (PR-reviewed, but still data) — tolerate broken
	# JSON, clamp counts to non-negative integers, and strip control characters so a crafted
	# filename cannot smuggle terminal escapes into the report. @tsv escapes tab/newline.
	rollup_files=0
	while IFS= read -r root; do
		[ -n "$root" ] || continue
		for j in "$root"/docs/ai-knowledge/.metrics/*.json; do
			[ -f "$j" ] || continue
			rollup_files=$((rollup_files + 1))
			jq -r --arg repo "$(basename "$root")" '
				def n(v): if (v | type) == "number" and v >= 0 then (v | floor) else 0 end;
				(.user | select(type == "string")) as $u
				| (.files // {}) | to_entries[] | select(.value | type == "object")
				| [$u, $repo + "/" + .key, n(.value.loads), n(.value.used), n(.value.ignored), n(.value.contradicted)]
				| @tsv' "$j" 2>/dev/null
		done
	done > "$team_tsv" <<-EOF
	$inv_roots
	EOF
	tr -d '\000-\010\013\014\016-\037' < "$team_tsv" > "$team_tsv.c" && mv "$team_tsv.c" "$team_tsv"

	echo
	if [ -s "$team_tsv" ]; then
		t_users=$(cut -f1 "$team_tsv" | sort -u | grep -c .)
		echo "-- team rollups (committed .metrics/*.json from ${t_users} user(s); the event sections above are this machine only) --"
		echo "top by team usage (summed across users):"
		awk -F'\t' '{u[$2] += $4; i[$2] += $5; c[$2] += $6; l[$2] += $3}
			END { for (k in u) printf "%d\t%d\t%d\t%d\t%s\n", u[k], i[k], c[k], l[k], k }' "$team_tsv" |
			sort -rn | head -8 |
			awk -F'\t' '{ printf "  used %s / ignored %s%s   %s (loads %s)\n", $1, $2, ($3 > 0 ? " / contradicted " $3 : ""), $5, $4 }'
		all_ignored=$(awk -F'\t' '{u[$2] += $4; i[$2] += $5}
			END { for (k in u) if (u[k] == 0 && i[k] >= 2) print "  " k " (ignored " i[k] ", used 0 — team-wide)" }' "$team_tsv" | sort)
		if [ -n "$all_ignored" ]; then
			echo "ignored by everyone (strong polish/retire signal):"
			printf '%s\n' "$all_ignored"
		fi
	elif [ "$rollup_files" -gt 0 ]; then
		echo "-- team rollups: ${rollup_files} file(s) committed, all empty (no events in their windows) --"
	else
		echo "-- team rollups: none committed yet (each member's memorize/consolidate refreshes docs/ai-knowledge/.metrics/<user>.json automatically; manual: lore-stats.sh export-summary) --"
	fi

	echo
	echo "-- never loaded (zero kb_load ever — mine or any committed rollup — written > 14 days ago; retire-or-activate candidates) --"
	jq -r "${JQARGS[@]}" "$JQDEF"'select(.event=="kb_load") | kbkey' "$tmp_all" 2>/dev/null | sort -u > "$loaded_keys"
	# Union in every file some teammate's rollup shows loads for
	awk -F'\t' '$3 > 0 { print $2 }' "$team_tsv" 2>/dev/null >> "$loaded_keys"
	sort -u -o "$loaded_keys" "$loaded_keys"
	never=$(awk -F'\t' -v d14="${d14:-0000-00-00}" '
		NR==FNR { seen[$0]=1; next }
		{ k=$1 "/" $2; if (!(k in seen) && ($5 == "" || $5 < d14)) printf "  %s (updated %s)\n", k, ($5=="" ? "?" : $5) }
	' "$loaded_keys" "$inv_tsv" | sort)
	if [ -n "$never" ]; then
		printf '%s\n' "$never"
		echo "  (note: worktree streams are merged into main repos; legacy kb_load rows from umbrella-dir sessions lack an owning-repo field, so the list may still run slightly long)"
	else
		echo "  (none: every inventory entry has been loaded at least once)"
	fi

	# ---------- anchor drift: the code an entry anchors to changed after the entry was last updated ----------
	# Dead anchors (file gone) are caught by gen --check; this catches the quieter case — the
	# file is still there but has moved on since the knowledge was written. Commit count since
	# `updated` per anchor, summed per entry. One `git log` per anchor: set LORE_STATS_SKIP_DRIFT=1
	# to skip on very large inventories.
	echo
	if [ "${LORE_STATS_SKIP_DRIFT:-0}" = "1" ]; then
		echo "-- anchor drift: skipped (LORE_STATS_SKIP_DRIFT=1) --"
	else
		echo "-- anchor drift (anchored code committed AFTER the entry's updated date — the code moved on; re-verify these first) --"
		# One `git log` per repo (not per anchor): a date-stamped file list since the oldest
		# `updated` in that repo, matched in awk against every entry's anchors (exact file, or
		# prefix for directory anchors), counting commits dated after each entry's own `updated`.
		# ~300 anchors used to mean ~300 git invocations (45s on a 27-repo umbrella); now 27.
		drift=$(printf '%s' "$inv_roots" | awk 'NF' | while IFS= read -r root; do
			oldest=$(awk -F'\t' -v r="$root" '$9 == r && $8 != "" && $5 != "" { print $5 }' "$inv_tsv" | sort | head -1)
			[ -n "$oldest" ] || continue
			git -C "$root" --no-optional-locks log --since="$oldest" --name-only --format='@%ad' --date=short 2>/dev/null |
				awk -F'\t' -v root="$root" '
					NR == FNR { if ($9 == root && $8 != "" && $5 != "") { n++; file[n] = $2; up[n] = $5; anc[n] = $8; repo[n] = $1 } next }
					/^@/ { cur = substr($0, 2); c++; next }
					NF == 0 { next }
					{
						for (i = 1; i <= n; i++) {
							if (cur <= up[i] || seen[i, c]) continue
							m = split(anc[i], A, "|")
							for (j = 1; j <= m; j++) {
								a = A[j]
								if (a == "") continue
								if (a == $0 || index($0, a "/") == 1 || (substr(a, length(a)) == "/" && index($0, a) == 1)) { cnt[i]++; seen[i, c] = 1; break }
							}
						}
					}
					END { for (i = 1; i <= n; i++) if (cnt[i] > 0) printf "%d\t  %d commit(s) since %s   %s/%s\n", cnt[i], cnt[i], up[i], repo[i], file[i] }
				' "$inv_tsv" -
		done | sort -rn | head -15 | cut -f2-)
		if [ -n "$drift" ]; then
			printf '%s\n' "$drift"
		else
			echo "  (none: no anchored file changed after its entry was last updated)"
		fi
	fi
fi

echo
echo "-- time-to-first-use (knowledge written → first load; never read = not reaching the retrieval surface, or the description lacks symptom words) --"
jq -s -r "${JQARGS[@]}" "$JQDEF"'
	[.[] | select(.event=="kb_write" and .verdict=="written")] as $w
	| [.[] | select(.event=="kb_load")] as $l
	| if ($w | length) == 0 then "  (no kb_write data yet; appears after memorize runs)"
	  else $w[] | . as $x | ($x | kbkey) as $k
		| ([$l[] | select(kbkey == $k and .ts > $x.ts)] | sort_by(.ts) | .[0]) as $f
		| if $f then "  \($k): first read \(((($f.ts | fromdate) - ($x.ts | fromdate)) / 8640 | round) / 10) day(s) later"
		  else "  \($k): never read yet (written \($x.ts[0:10]))" end
	  end
' "$tmp_all" 2>/dev/null

echo
echo "How to read this: low response rate = the gate instruction gets ignored; written stuck at 0 = fires without a capture habit;"
echo "  polish candidates = retrieved but not helping; never loaded = retire-or-activate; unresolved contradictions = the code moved"
echo "  and the knowledge didn't — consolidate verifies those first; last-14-days hit rate below the historical rate = fresh"
echo "  feedback quality is slipping, don't be comforted by the cumulative number."
