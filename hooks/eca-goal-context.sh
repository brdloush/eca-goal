#!/usr/bin/env bash
# eca-goal: ECA postCompact / chatStart hook. Re-injects the active goal after
# compaction, or when an owning chat starts or resumes.
set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=eca-goal-lib.sh
. "$here/eca-goal-lib.sh"

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
chat_id=$(jq -r '.chat_id // empty' <<<"$input")
goal="$cwd/$ECA_GOAL_REL_DIR/goal.md"; loop="$cwd/$ECA_GOAL_REL_DIR/loop.json"
[ -n "$cwd" ] && [ -f "$goal" ] || exit 0

# Only the owning chat gets the goal. Notices for other chats come from the loop
# hook at the end of a turn: on a new chat, chatStart runs BEFORE the preRequest
# hook has seen a typed /goal-resume, so a notice here could be wrong.
case "$(goal_get "$goal" status)" in active|claimed|auditing) ;; *) exit 0 ;; esac
[ "$(loop_get "$loop" .owner)" = "$chat_id" ] || exit 0

jq -n --rawfile g "$goal" '{additionalContext: ("An autonomous goal is active (eca-goal). .eca/eca-goal/goal.md is your durable state. Current content:\n\n" + $g)}'
