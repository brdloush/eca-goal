#!/usr/bin/env bash
# eca-goal: ECA postRequest hook. Drives the goal loop from .eca/eca-goal/goal.md.
#
# The agent decides when it believes the goal is met. The loop decides whether
# that belief holds. After each primary-agent turn:
#   - status active  -> run the check (if any). Fails -> followUp "do the next
#                       step"; the same failure again and again -> pause (stall).
#                       Passes, or no check -> followUp "continue, or claim".
#   - status claimed -> the agent claims the goal is met and wrote proof.md.
#                       The loop checks the proof format, runs the check, re-runs
#                       every "command:" line of the proof, and the optional LLM
#                       judge. Any failure -> back to work. Only a judge "no"
#                       counts as a rejected claim; a failing check or proof
#                       command uses the stall rule instead. All pass -> one
#                       verification turn.
#   - verification   -> a fresh reviewer subagent checks the proof. It sorts
#                       problems into blocking and minor, and from round 2 on it
#                       first checks its earlier findings (review-<N>.md). The
#                       turn must end with "verified: yes", review.md
#                       "verdict: pass" with an empty "## Blocking" list, and the
#                       check must still pass. Otherwise the claim is rejected ->
#                       back to work, and review.md is kept as review-<N>.md.
# Too many rejected claims pause the goal (claims-rejected). A paused goal is
# reported once in the owning chat.
set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=eca-goal-lib.sh
. "$here/eca-goal-lib.sh"

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
chat_id=$(jq -r '.chat_id // empty' <<<"$input")
agent=$(jq -r '.agent // empty' <<<"$input")
goal="$cwd/$ECA_GOAL_REL_DIR/goal.md"
[ -n "$cwd" ] && [ -f "$goal" ] || exit 0
goal_ensure_gitignore "$cwd"

loop="$cwd/$ECA_GOAL_REL_DIR/loop.json"
proof="$cwd/$ECA_GOAL_REL_DIR/proof.md"
review="$cwd/$ECA_GOAL_REL_DIR/review.md"
state_dir="$cwd/$ECA_GOAL_REL_DIR"
status=$(goal_get "$goal" status)
owner=$(loop_get "$loop" .owner)
tracked=$(loop_get "$loop" .tracked)           # the loop has run this goal while it was active
confirmed=$(loop_get "$loop" .done_confirmed)
audit_pending=$(loop_get "$loop" .audit_pending) # the loop itself started the current verification
lines=${ECA_GOAL_OUTPUT_LINES:-60}

# say_once KEY MESSAGE -> show a systemMessage once per chat (for skip reasons), then exit
say_once() {
  if [ "$(jq -r --arg c "$chat_id" '.told[$c] // empty' "$loop" 2>/dev/null)" != "$1" ]; then
    loop_update "$loop" '.told[$c] = $k' --arg c "$chat_id" --arg k "$1"
    jq -n --arg m "eca-goal: $2" '{systemMessage: $m}'
  fi
  exit 0
}

# "done" written by the agent itself, while the loop was running this goal, is
# not accepted: it goes through the loop like any other turn.
unconfirmed_done=0
note=""
if [ "$status" = "done" ] && [ "$tracked" = true ] && [ "$confirmed" != true ] && [ "$owner" = "$chat_id" ]; then
  unconfirmed_done=1
  note="\`status: done\` was set without the loop confirming it. To finish, write the proof and set \`status: claimed\`; the loop verifies the claim."$'\n'
  goal_set "$goal" status active
  status=active
fi
if [ "$status" = "done" ] && [ "$confirmed" != true ] && [ "$unconfirmed_done" = 0 ]; then
  say_once unconfirmed "goal.md says done, but the loop never confirmed it (the claim was not verified). Type /goal-resume to verify it."
fi
# A paused goal is silent otherwise, so say once in the owning chat how to go on
# (not for /goal-pause: the user just typed it).
if [ "$status" = paused ] && [ -n "$owner" ] && [ "$owner" = "$chat_id" ]; then
  why=$(goal_get "$goal" paused_reason)
  [ "$why" = manual ] || say_once "paused-${why:-none}" "the goal is paused (${why:-no reason given}), so the loop is NOT running. Type /goal-resume to continue."
fi
case "$status" in active|claimed|auditing) ;; *) exit 0 ;; esac

# Ownership comes only from loop.json, set when a human types /goal or
# /goal-resume in a chat (preRequest hook). The header cannot change it.
if [ -z "$owner" ]; then
  say_once unowned "an active goal exists in .eca/eca-goal/goal.md, but no chat owns it, so the loop is NOT running. Type /goal-resume in the chat that should work on it."
fi
if [ "$owner" != "$chat_id" ]; then
  say_once foreign "the active goal is owned by another chat, so the loop is NOT running here. Type /goal-resume to move it to this chat."
fi
[ "$tracked" = true ] || loop_update "$loop" '.tracked = true'

# pause REASON MESSAGE -> set status paused with a machine-readable reason
pause() {
  goal_set "$goal" status paused
  goal_set "$goal" paused_reason "$1"
  jq -n --arg m "Goal paused ($1): $2 Use /goal-resume to continue." '{systemMessage: $m}'
  exit 0
}

# A turn stopped by the user still fires postRequest (ECA drops the followUp).
# ECA builds that hook input without "agent", so use it to detect the stop and
# pause instead of running a possibly slow check for nothing.
[ -n "$agent" ] || pause user-stop "the turn was stopped."

check=$(goal_get "$goal" check)

# run_check -> rc, tail_out, check_secs. The time goes to loop.json. A slow check
# sets slow_hint; the next work followUp shows it (once per goal), not the
# verification turn, where the agent must do no other work.
check_secs=0; slow_hint=""
run_check() {
  if [ -n "$check" ]; then
    local t0=$SECONDS slow=${ECA_GOAL_SLOW_CHECK:-120}
    out=$(cd "$cwd" && timeout "${ECA_GOAL_CHECK_TIMEOUT:-900}" bash -c "$check" 2>&1 </dev/null); rc=$?
    check_secs=$((SECONDS - t0))
    loop_update "$loop" '.check_secs = ($s | tonumber)' --arg s "$check_secs"
    tail_out=$(tail -n "$lines" <<<"$out")
    [ "$rc" -eq 124 ] && tail_out="$tail_out
(eca-goal: check timed out after ${ECA_GOAL_CHECK_TIMEOUT:-900}s)"
    if [ "$check_secs" -gt "$slow" ] && [ "$(loop_get "$loop" .slow_warned)" != true ]; then
      slow_hint="The check took ${check_secs}s. It runs after every turn, at every claim and before done. Make it faster if you can, without sacrificing correctness (run the test suite once, do not call other check scripts). If you cannot, write why under Notes."$'\n'
    fi
  else
    rc=0; tail_out="(no check command)"
  fi
}

# "auditing" written by the agent (not by the loop) counts as a claim at most:
# the loop starts the verification itself, after the claim passed its checks.
if [ "$status" = auditing ] && [ "$audit_pending" != true ]; then
  note="\`status: auditing\` was set by you, not by the loop. The loop starts the verification itself, after your claim passes its checks. It treated this as \`status: claimed\`."$'\n'
  goal_set "$goal" status claimed
  status=claimed
fi

# End of a verification turn that the loop started. The goal is done only with
# "verified: yes", a reviewer verdict of pass with no blocking findings, and a
# check that still passes (the agent may have fixed minor findings in this
# turn). Anything else rejects the claim.
audit_failed=""; recheck_out=""
if [ "$audit_pending" = true ]; then
  loop_update "$loop" '.audit_pending = false'
  verdict=$(review_verdict "$review")
  verified=$(goal_get "$goal" verified)
  blocking=$(review_blocking "$review")
  if [ "$status" != auditing ]; then audit_failed="you set \`status: $status\` during the verification"
  elif [ "$verdict" != pass ]; then audit_failed="\`.eca/eca-goal/review.md\` does not say \`verdict: pass\`"
  elif [ -n "$blocking" ]; then audit_failed="\`.eca/eca-goal/review.md\` says \`verdict: pass\`, but its \`## Blocking\` list is not empty"
  elif [ "$verified" != yes ]; then audit_failed="the verification turn ended without \`verified: yes\`"
  else
    run_check
    if [ "$rc" -eq 0 ]; then
      loop_update "$loop" '.done_confirmed = true'
      goal_set "$goal" status "done"
      jq -n '{systemMessage: "Goal done (confirmed by the loop). See .eca/eca-goal/goal.md, proof.md, review.md and .eca/rules/eca-goal-lessons.md."}'
      exit 0
    fi
    audit_failed="the check fails after the verification turn (a fix in that turn broke something)"
    recheck_out="Check \`$check\` exited $rc. Last output:
\`\`\`
$tail_out
\`\`\`
"
  fi
  goal_set "$goal" status active
  goal_set "$goal" verified no
  status=active
fi

cur=$(loop_get "$loop" .iteration); iter=$(( ${cur:-0} + 1 ))
max=$(goal_get "$goal" max_iterations); max=${max:-50}
loop_update "$loop" '.iteration = ($i | tonumber)' --arg i "$iter"
goal_set "$goal" iteration "$iter" # mirror for humans; the loop reads loop.json
[ "$iter" -le "$max" ] || pause budget "max_iterations ($max) reached. Raise max_iterations in .eca/eca-goal/goal.md if the goal needs more turns."

# followup SYSTEM_MESSAGE TEXT -> print a work followUp (TEXT + the standing rules), then exit
followup() {
  [ -z "$slow_hint" ] || loop_update "$loop" '.slow_warned = true'
  jq -n --arg s "$1" --arg t "$note$2$slow_hint" '{
    systemMessage: $s,
    followUp: ($t
      + "Re-read .eca/eca-goal/goal.md. Pick the next step and do it. Then update the Progress section: what you did, what worked, what failed, next step.\n"
      + "At the end of each turn, ask yourself: is every \"Done when\" item met? If yes, write .eca/eca-goal/proof.md (one `## ` section per \"Done when\" item, each with `method: check | command | file-read | judgement`, `command:` lines for method command, and `evidence:`; use `check` when the goal check proves the item, and `command` only for cheap commands the check does not cover), set `status: claimed`, and end your turn. The loop then verifies your claim.\n"
      + "You do not need to run the check or the proof commands yourself just before you claim: the loop runs them right after your turn, and a failing check or proof command costs one turn, not a rejected claim.\n"
      + "Delegate independent research to subagents with `eca__spawn_agent`: `explorer` to find files and read code (read-only), `general` for multi-step side tasks. When the parts are independent (for example, several screens or modules to map), start them in the same response so they run in parallel. Give each one a precise task and ask for a short result. Keep all edits, and the change -> check -> fix cycle, in the main agent.\n"
      + "Work autonomously. When you face a choice you can make yourself, pick the most reasonable option, write it under Notes with a one-line reason, and continue. Set `status: paused` and `paused_reason: needs-human` ONLY when you need something only a human can give (credentials, access, an irreversible or outward-facing action, requirements that conflict).\n"
      + "Do not commit unless the goal text asks for it. Never push.")
  }'
  exit 0
}

# reject WHY -> count a rejected claim (pause after claim_limit), status back to active
reject() {
  local n prev limit
  goal_set "$goal" status active
  prev=$(loop_get "$loop" .claim_rejects); n=$(( ${prev:-0} + 1 ))
  loop_update "$loop" '.claim_rejects = ($n | tonumber)' --arg n "$n"
  limit=$(goal_get "$goal" claim_limit); limit=${limit:-3}
  [ "$n" -lt "$limit" ] || pause claims-rejected "$n claims were rejected ($1). Read .eca/eca-goal/review.md and Progress, then make the \"Done when\" items clearer or help the agent."
  note="${note}Your claim was rejected (${n}/${limit}): $1."$'\n'
}

# stall_step SIG -> sets stall: how many failures in a row had this same signature
# (exit code + output), this one included. Kept in loop.json.
stall_step() {
  local prev
  if [ "$1" = "$(loop_get "$loop" .stall_sig)" ]; then
    prev=$(loop_get "$loop" .stall_count); stall=$(( ${prev:-0} + 1 ))
  else
    stall=1
  fi
  loop_update "$loop" '.stall_sig = $s | .stall_count = ($n | tonumber)' --arg s "$1" --arg n "$stall"
}

# check_failed -> stall detection, then the "not met" followUp. The same failure
# (exit code + output) again and again means the last turns changed nothing the
# check can see. A broken check (command not found / not executable) pauses
# sooner. A check with no output gives nothing to compare, so it is never
# counted as a stall (max_iterations still applies).
check_failed() {
  local stall limit hint=""
  if [ -z "$tail_out" ] && [ "$rc" != 126 ] && [ "$rc" != 127 ]; then
    stall=0; loop_update "$loop" '.stall_sig = "" | .stall_count = 0'
  else
    stall_step "$(printf '%s\n%s' "$rc" "$tail_out" | cksum | cut -d' ' -f1)"
  fi
  limit=$(goal_get "$goal" stall_limit); limit=${limit:-3}
  case "$rc" in
    126|127) limit=2
             hint="The check command itself cannot run (exit $rc: not found / not executable). Fix the environment if you can (install the tool, fix the path). Change the \`check\` line only if the check itself is wrong, and write why under Notes."$'\n' ;;
    124)     hint="The check timed out. Make it faster or narrower if you can, and write why under Notes."$'\n' ;;
  esac
  if [ "$stall" -gt 0 ] && [ "$stall" -ge "$limit" ]; then
    case "$rc" in
      126|127) pause check-broken "the check command cannot run (exit $rc), $stall times in a row." ;;
      *)       pause stall "the check failed $stall times in a row with the same output." ;;
    esac
  fi
  [ "$stall" -ge 2 ] && hint="${hint}WARNING: the check output is exactly the same as after the previous turn, so your last change had no effect the check can see. Try a different approach. If this happens again, the goal pauses."$'\n'
  followup "Goal not met (iteration $iter/$max)." "Goal not met yet (iteration $iter/$max).
Check \`$check\` exited $rc. Last output:
\`\`\`
$tail_out
\`\`\`
$hint"
}

# validate_proof -> one "- problem" line per format problem (none = ok)
validate_proof() {
  local n_items n_sections kind title method ev tab=$'\t'
  if [ ! -s "$proof" ]; then echo "- .eca/eca-goal/proof.md is missing or empty"; return; fi
  n_items=$(goal_items "$goal" | wc -l)
  n_sections=$(grep -c '^S' <<<"$parsed")
  [ "$n_items" -gt 0 ] || echo "- goal.md has no \"- \" items under \"## Done when\""
  [ "$n_sections" -ge "$n_items" ] || echo "- proof.md has $n_sections \`## \` sections, but goal.md has $n_items \"Done when\" items (one section per item)"
  while IFS=$'\t' read -r kind title method ev; do
    [ "$kind" = S ] || continue
    case "$method" in
      command) grep -qF "C$tab$title$tab" <<<"$parsed" || echo "- \"$title\": \`method: command\` needs at least one \`command:\` line" ;;
      check) [ -n "$check" ] || echo "- \"$title\": \`method: check\`, but goal.md has no check command (use command, file-read or judgement)" ;;
      file-read|judgement) ;;
      *) echo "- \"$title\": \`method:\` must be check, command, file-read or judgement (got \"$method\")" ;;
    esac
    [ "$ev" = 1 ] || echo "- \"$title\": no \`evidence:\` line"
  done <<<"$parsed"
}

# A claim that failed its verification goes back to work with the reviewer's findings.
# The review is kept as review-<N>.md, so the next reviewer can check its own
# earlier findings instead of starting from zero.
if [ -n "$audit_failed" ]; then
  kept=""
  if [ -f "$review" ]; then
    round=$(( $(review_history "$state_dir" | wc -l) + 1 ))
    cp "$review" "$state_dir/review-$round.md" && kept=" (kept as .eca/eca-goal/review-$round.md; the next reviewer checks these findings first)"
  fi
  reject "$audit_failed"
  findings=$( [ -f "$review" ] && tail -n "$lines" "$review" )
  followup "Goal claim rejected by the verification (iteration $iter/$max)." "The verification did not confirm the goal (iteration $iter/$max).
$recheck_out${findings:+Reviewer findings$kept:
\`\`\`
$findings
\`\`\`
}Fix every blocking finding. Fix the minor ones too if it is cheap. Update .eca/eca-goal/proof.md, then claim again.
"
fi

if [ "$status" != claimed ]; then
  run_check
  [ "$rc" -eq 0 ] || check_failed
  loop_update "$loop" '.stall_count = 0'
  if [ -n "$check" ]; then
    followup "Goal check passes, not claimed yet (iteration $iter/$max)." "The check \`$check\` passes (iteration $iter/$max), but you have not claimed the goal yet. If every \"Done when\" item is met, write the proof and claim it now. If not, continue the work.
"
  fi
  followup "Goal in progress (iteration $iter/$max, no check command)." "Goal in progress (iteration $iter/$max). This goal has no check command: your proof and the reviewer decide when it is done.
"
fi

# status: claimed. 1) proof format
parsed=$(proof_parse "$proof" 2>/dev/null)
problems=$(validate_proof)
if [ -n "$problems" ]; then
  goal_set "$goal" status active
  followup "Goal claim not accepted: the proof is incomplete (iteration $iter/$max)." "Your claim was not accepted: .eca/eca-goal/proof.md is incomplete (iteration $iter/$max).
$problems
Format, one section per \"Done when\" item:
\`\`\`
## <the Done when item>
method: check | command | file-read | judgement
command: <one shell line that exits 0 only if the item is met; repeat the line for more; method command only>
evidence: <what you saw: command output, file:line, or your reasoning>
confidence: high | medium | low
\`\`\`
Fix the proof, then set \`status: claimed\` again.
"
fi

# 2) the check. A failing check or proof command sends the agent back to work,
#    but it is not a rejected claim (claim_limit): the stall rule stops a loop.
#    So the agent does not need to run them itself before it claims.
run_check
if [ "$rc" -ne 0 ]; then
  goal_set "$goal" status active
  note="${note}Your claim was not accepted: the check fails. This does not count as a rejected claim."$'\n'
  check_failed
fi

# 3) every "command:" line of the proof, run by the loop itself. A command that
#    is listed more than once (for several items) runs only once.
fails=""; ncmd=0
ran_cmd=(); ran_rc=(); ran_out=()   # indexed arrays: no bash 4 needed
while IFS=$'\t' read -r kind title cmd; do
  [ "$kind" = C ] || continue
  k=0
  while [ "$k" -lt "$ncmd" ] && [ "${ran_cmd[$k]}" != "$cmd" ]; do k=$((k + 1)); done
  if [ "$k" -eq "$ncmd" ]; then
    ran_cmd[$k]=$cmd
    ran_out[$k]=$(cd "$cwd" && timeout "${ECA_GOAL_CHECK_TIMEOUT:-900}" bash -c "$cmd" 2>&1 </dev/null)
    ran_rc[$k]=$?
    ncmd=$((ncmd + 1))
  fi
  [ "${ran_rc[$k]}" -eq 0 ] || fails+="- \"$title\": \`$cmd\` exited ${ran_rc[$k]}. Last output:
\`\`\`
$(tail -n 20 <<<"${ran_out[$k]}")
\`\`\`
"
done <<<"$parsed"
if [ -n "$fails" ]; then
  goal_set "$goal" status active
  stall_step "$(printf '%s' "$fails" | cksum | cut -d' ' -f1)"
  limit=$(goal_get "$goal" stall_limit); limit=${limit:-3}
  [ "$stall" -lt "$limit" ] || pause stall "a proof command failed $stall times in a row with the same output."
  hint=""
  [ "$stall" -ge 2 ] && hint="WARNING: the same proof commands fail with the same output as at your previous claim. Fix the work, or the command if the command is wrong. If this happens again, the goal pauses."$'\n'
  followup "Goal claim not accepted: a proof command fails (iteration $iter/$max)." "Your claim was not accepted: the loop re-ran the commands in your proof, and some fail, so these items are not met (iteration $iter/$max). This does not count as a rejected claim.
$fails$hint"
fi
loop_update "$loop" '.stall_count = 0'

# 4) Optional LLM judge (OpenAI-compatible endpoint). It runs only after the
#    mechanical checks passed, so it can only make the loop stricter.
if [ "$(goal_get "$goal" judge)" = local ]; then
  url=${ECA_GOAL_JUDGE_URL:-}
  if [ -z "$url" ]; then
    reject "the judge cannot run"
    followup "Goal claim rejected: judge not configured (iteration $iter/$max)." "\`judge: local\` is set, but ECA_GOAL_JUDGE_URL is not set in ECA's environment, so the claim cannot be judged. Set \`judge: off\` if the reviewer is enough, and write why under Notes.
"
  fi
  done_when=$(sed -n '/^## Done when/,/^## [^D]/p' "$goal")
  resp=$(jq -r '.response // ""' <<<"$input" | tail -c 6000)
  prf=$(tail -c 8000 "$proof")
  prompt=$(jq -n --arg d "$done_when" --arg p "$prf" --arg c "$tail_out" --arg r "$resp" \
    '"Completion condition:\n\($d)\n\nProof by the agent:\n\($p)\n\nCheck output:\n\($c)\n\nAgent last message:\n\($r)\n\nJudge ONLY from this evidence. Is every condition fully met? Reply JSON: {\"met\": true|false, \"reason\": \"short\"}"')
  body=$(jq -n --argjson p "$prompt" --arg m "${ECA_GOAL_JUDGE_MODEL:-}" \
    '{messages: [{role: "user", content: $p}], temperature: 0, response_format: {type: "json_object"}}
     + (if $m != "" then {model: $m} else {} end)')
  auth=(); [ -n "${ECA_GOAL_JUDGE_API_KEY:-}" ] && auth=(-H "Authorization: Bearer $ECA_GOAL_JUDGE_API_KEY")
  verdict=$(curl -s --max-time "${ECA_GOAL_JUDGE_TIMEOUT:-180}" "${url%/}/v1/chat/completions" \
    -H 'Content-Type: application/json' "${auth[@]}" -d "$body" \
    | jq -r '.choices[0].message.content // "{}"' 2>/dev/null)
  met=$(jq -r '.met // false' <<<"$verdict" 2>/dev/null)
  reason=$(jq -r '.reason // empty' <<<"$verdict" 2>/dev/null)
  reason=${reason:-"no verdict (judge unreachable or bad JSON)"}
  if [ "$met" != true ]; then
    reject "the judge says not met"
    followup "Goal claim rejected by the judge (iteration $iter/$max)." "Judge says: $reason
"
  fi
fi

# 5) All mechanical checks passed -> the verification turn with a fresh reviewer.
#    From round 2 on, the reviewer also gets its earlier reviews.
rm -f "$review"
hist=$(review_history "$state_dir" | sed "s|^$state_dir/|.eca/eca-goal/|" | paste -sd ' ')
vround=$(( $(review_history "$state_dir" | wc -l) + 1 ))
loop_update "$loop" '.audit_pending = true'
goal_set "$goal" verified no
goal_set "$goal" status auditing
# The reviewer is told what the loop already ran on this tree, so it does not
# run it again. That is safe: these exit codes come from the hook (a script),
# not from the agent, so the agent still does not grade its own work.
jq -n --arg i "$iter" --arg n "$ncmd" --arg c "${check:-(none)}" --arg note "$note" --arg h "$hist" --argjson r "$vround" \
  --arg hc "${check:+1}" --arg secs "$check_secs" --arg ctail "$(tail -n 20 <<<"$tail_out")" '{
  systemMessage: "Goal claim passed the mechanical checks (iteration \($i)). Running the verification (review round \($r)).",
  followUp: ($note
    + "Your claim passed the mechanical checks: the check `\($c)` passes, and the loop re-ran the \($n) command(s) in your proof. Now the verification (review round \($r)). Do no other work in this turn, except the minor fixes in step 3.\n"
    + "1. Start ONE fresh reviewer with `eca__spawn_agent` (`general`). Give it only: the Objective and the \"Done when\" items from .eca/eca-goal/goal.md, the path .eca/eca-goal/proof.md"
    + (if $h != "" then ", and the earlier reviews: \($h)" else "" end)
    + ". Do NOT give it your chat history or your opinion. Tell it:\n"
    + "   - Inspect the working tree yourself (git diff, read files, run commands). Trust nothing the proof claims without checking it.\n"
    + (if $hc != "" or $n != "0" then
        "   - The loop (a script, not the agent) already ran "
      + ([ (if $hc != "" then "the check `\($c)` (exit 0, \($secs)s)" else empty end),
           (if $n != "0" then "the \($n) proof command(s)" else empty end) ] | join(" and "))
      + " on this exact working tree, and they pass. Do not re-run them: read them, and decide whether they really prove the items. Run commands only for what they do not cover (one focused test, one grep)."
      + (if $hc != "" and ($secs | tonumber) >= 60 then " If you must run a long command (like the check), use a timeout above \($secs)s." else "" end)
      + "\n"
      else "" end)
    + (if $hc != "" then "   - The last lines of the check output:\n```\n\($ctail)\n```\n" else "" end)
    + "   - For each \"Done when\" item, reply `ok` or `not-ok` with a one-line reason. For `command` items, check that the command really proves the item (it is not trivially true, it tests the right thing). For `check` items, read the check (the command, and the script it calls) and confirm that it really tests this item. For `file-read` and `judgement` items, read the files and judge them yourself. If the evidence is weak, the item is `not-ok`.\n"
    + "   - Look for concrete errors in what the goal produced (a wrong fact, a wrong `file:line` reference, a broken example, code that does not work), and sort every problem into one of two classes, each with the exact place and the fix. BLOCKING: a \"Done when\" item is not met, a check is weakened or broken, or the proof claims something false. MINOR: a wrong number or wording in prose, an outdated comment, style. Only blocking problems make an item `not-ok`.\n"
    + (if $r > 1 then
        "   - This is review round \($r). Read the earlier reviews first. Start the answer with `## Previous findings`: for each earlier blocking finding, `fixed` or `not fixed`, with a one-line reason. A blocking finding that is not fixed stays blocking.\n"
      + "   - A NEW blocking problem in this round must be either in something that changed since the earlier review, or serious (an item is not met, a check is broken or weakened, the proof claims something false). Parts that did not change since the earlier review get minor findings only. Do not hunt for new reasons to fail: the question is whether the work is done.\n"
      else "" end)
    + "   - Judge only the Objective and the \"Done when\" items. Problems outside them are weak points, not blocking.\n"
    + "   - Name at least one weak point of the work (matters of taste or scope), or say why there is none.\n"
    + "   - Use this format: first line `verdict: pass` or `verdict: fail`, then "
    + (if $r > 1 then "`## Previous findings`, " else "" end)
    + "`## Items`, `## Blocking`, `## Minor`, `## Weak points`. Write `- none` under an empty list. `verdict: pass` only if `## Blocking` is empty.\n"
    + "2. Write the reviewer answer, unchanged, to .eca/eca-goal/review.md.\n"
    + "3. If the verdict is pass: fix the minor findings, but only in prose, docs and comments (no code, no checks, no tests). Then set `verified: yes` in the header of .eca/eca-goal/goal.md, append 1-5 durable, repo-specific lessons (do / do not) to .eca/rules/eca-goal-lessons.md (create it if missing). Write lessons about this repo (its code, tools, tests and traps), not about the goal loop itself (claiming, proofs, re-running commands): its instructions cover that, and they can change. Then write a short final summary that lists any minor finding you did not fix. The loop runs the check once more before it marks the goal done.\n"
    + "   If the verdict is fail: leave `verified: no` and end the turn. The loop sends you back to work with the findings.\n"
    + "The goal is done ONLY if this turn ends with `verified: yes`, review.md says `verdict: pass` with an empty `## Blocking` list, and the check still passes.")
}'
