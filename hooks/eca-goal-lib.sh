#!/usr/bin/env bash
# eca-goal: shared helpers.
#
# State files in .eca/eca-goal/:
#   goal.md    - the goal, written by the agent and by you. It starts with a
#                header of "key: value" lines, ended by a line that is exactly
#                "---". Only the header is read and written here, so text in the
#                body (Plan, Progress, ...) can never be mistaken for a state key.
#   loop.json  - loop bookkeeping, written ONLY by the hooks: which chat owns the
#                goal (set when you type /goal or /goal-resume), the iteration
#                counter, stall detection, and whether "done" was confirmed by
#                the loop. The agent cannot turn the loop off by editing goal.md.
#   proof.md   - written by the agent when it claims the goal: one "## " section
#                per "Done when" item, with method:, command: and evidence: lines.
#   review.md  - the fresh reviewer's answer in the verification turn. The loop
#                reads its first "verdict:" line (pass / fail) and its
#                "## Blocking" list.
#   review-<N>.md - earlier reviews (round N), saved by the loop when a
#                verification fails. The next reviewer reads them first.

ECA_GOAL_REL_DIR=".eca/eca-goal"

# goal_get FILE KEY -> value (empty if missing)
goal_get() {
  awk -v k="$2" '
    $0 == "---" { exit }
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }
  ' "$1"
}

# goal_set FILE KEY VALUE -> rewrite (or add) KEY in the header only
goal_set() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  awk -v k="$2" -v v="$3" '
    BEGIN { done = 0; in_header = 1 }
    in_header && $0 == "---" { if (!done) print k ": " v; done = 1; in_header = 0; print; next }
    in_header && index($0, k ":") == 1 { if (!done) print k ": " v; done = 1; next }
    { print }
    END { if (!done) print k ": " v }
  ' "$1" >"$tmp" && mv "$tmp" "$1"
}

# goal_ensure_gitignore CWD -> keep the state dir out of git without touching the repo .gitignore
goal_ensure_gitignore() {
  local dir="$1/$ECA_GOAL_REL_DIR"
  [ -d "$dir" ] && [ ! -e "$dir/.gitignore" ] && printf '*\n' >"$dir/.gitignore"
  return 0
}

# loop_get FILE JQ_PATH -> raw value ("" if missing or no file)
loop_get() {
  [ -f "$1" ] || return 0
  jq -r "$2 // empty" "$1" 2>/dev/null
}

# loop_update FILE JQ_FILTER [jq args...] -> apply a jq filter to loop.json (created as {} if missing)
loop_update() {
  local file=$1 filter=$2 tmp; shift 2
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] && jq -e 'type == "object"' "$file" >/dev/null 2>&1 || echo '{}' >"$file"
  tmp=$(mktemp "$file.XXXXXX") || return 1
  jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

# goal_items FILE -> the "- " items under "## Done when", one per line
goal_items() {
  awk '/^## Done when/ { f = 1; next } /^## / { f = 0 } f && /^[ \t]*- / { sub(/^[ \t]*- /, ""); print }' "$1"
}

# proof_parse FILE -> one line per proof section and per command in it:
#   S<TAB>title<TAB>method<TAB>has_evidence(0|1)
#   C<TAB>title<TAB>command
proof_parse() {
  awk '
    function val(s) { s = substr(s, index(s, ":") + 1); sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function emit() { if (t != "") printf "S\t%s\t%s\t%d\n", t, m, ev }
    /^## / { emit(); t = substr($0, 4); m = ""; ev = 0; next }
    t == "" { next }
    /^method:/   { m = tolower(val($0)) }
    /^evidence:/ { ev = 1 }
    /^command:/  { c = val($0); if (c != "") printf "C\t%s\t%s\n", t, c }
    END { emit() }
  ' "$1"
}

# review_verdict FILE -> the value of the first "verdict:" line (lowercase), or empty
review_verdict() {
  [ -f "$1" ] || return 0
  awk '/^verdict:/ { v = tolower(substr($0, 9)); gsub(/[ \t\r]/, "", v); print v; exit }' "$1"
}

# review_blocking FILE -> the list items under "## Blocking" ("- none" and empty lists print nothing)
review_blocking() {
  [ -f "$1" ] || return 0
  awk '
    /^## / { f = ($0 ~ /^## Blocking/); next }
    f && /^[ \t]*[-*] / { l = tolower($0); gsub(/[^a-z]/, "", l); if (l != "none" && l != "nothing" && l != "") print }
  ' "$1"
}

# review_history DIR -> earlier reviews (review-1.md, review-2.md, ...), in round order, one path per line
review_history() {
  ls "$1"/review-[0-9]*.md 2>/dev/null | sort -V
}
