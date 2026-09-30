#!/usr/bin/env bash
# eca-goal: ECA preRequest hook. Sees the raw text YOU typed, before ECA expands
# a slash command. So only a human can claim, resume or pause a goal:
#   /goal ...         -> this chat owns the new goal; loop counters, proof and reviews reset
#   /goal-resume ...  -> this chat owns the goal; status active; counters and review.md reset
#                        (the review history review-<N>.md is kept, so the next reviewer remembers it)
#   /goal-pause ...   -> status paused (paused_reason: manual)
# /goal-resume also injects the goal, since chatStart ran before this hook.
# Any other prompt: no output, no effect.
set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=eca-goal-lib.sh
. "$here/eca-goal-lib.sh"

input=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$input")
cmd=$(sed -nE '1s/^[[:space:]]*\/(goal|goal-resume|goal-pause)([[:space:]].*)?$/\1/p' <<<"$prompt")
[ -n "$cmd" ] || exit 0
cwd=$(jq -r '.cwd // empty' <<<"$input")
chat_id=$(jq -r '.chat_id // empty' <<<"$input")
[ -n "$cwd" ] && [ -n "$chat_id" ] || exit 0
dir="$cwd/$ECA_GOAL_REL_DIR"; goal="$dir/goal.md"; loop="$dir/loop.json"
now=$(date -Iseconds)

case "$cmd" in
  goal)
    mkdir -p "$dir"; goal_ensure_gitignore "$cwd"
    rm -f "$dir/proof.md" "$dir/review.md" "$dir"/review-[0-9]*.md
    jq -n --arg c "$chat_id" --arg t "$now" '{owner: $c, claimed_at: $t, claimed_by: "/goal", iteration: 0}' >"$loop" ;;
  goal-resume)
    [ -f "$goal" ] || exit 0
    loop_update "$loop" '{owner: $c, claimed_at: $t, claimed_by: "/goal-resume", iteration: 0}' --arg c "$chat_id" --arg t "$now"
    goal_set "$goal" status active
    goal_set "$goal" paused_reason ""
    goal_set "$goal" verified no
    goal_set "$goal" iteration 0
    rm -f "$dir/review.md"
    jq -n --rawfile g "$goal" '{additionalContext: ("eca-goal: this chat now owns the goal. .eca/eca-goal/goal.md is your durable state. Current content:\n\n" + $g)}' ;;
  goal-pause)
    [ -f "$goal" ] || exit 0
    goal_set "$goal" status paused
    goal_set "$goal" paused_reason manual ;;
esac
exit 0
