#!/usr/bin/env bash
# eca-goal test suite: installer (in a temp config dir) and hook logic (with fake ECA input).
# Usage: test/run-tests.sh [--no-schema]   (--no-schema skips the tests that need a schema validator)
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SCHEMA_TESTS=1; [ "${1:-}" = --no-schema ] && SCHEMA_TESTS=0
pass=0; fail=0
check() { # check NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL %s\n' "$name"; fi
}
install_() { "$REPO/install.sh" --no-schema "$@" >"$T/out.log" 2>&1; }
hooks_of() { jq -r '.hooks // {} | keys[]' "$1/config.json" | tr '\n' ' '; }
not() { ! "$@"; }
backups() { ls "$1"/config.json.bak.eca-goal.* 2>/dev/null | wc -l; }

echo "== installer"

C=$T/empty
check "install into a dir with no config.json" install_ --config-dir "$C"
check "  config.json created with 4 eca-goal hooks" test "$(jq '.hooks | keys | length' "$C/config.json")" = 4
check "  hooks are symlinks into the repo" test "$(readlink "$C/hooks/eca-goal-loop.sh")" = "$REPO/hooks/eca-goal-loop.sh"
check "  commands dir is linked" test "$(readlink "$C/commands/eca-goal")" = "$REPO/commands"
check "  hook file paths point to the config hooks dir" \
  test "$(jq -r '.hooks["eca-goal-loop"].actions[0].file' "$C/config.json")" = "$C/hooks/eca-goal-loop.sh"

C=$T/existing; mkdir -p "$C"
cat >"$C/config.json" <<'EOF'
{
  "defaultModel": "x/y",
  "hooks": {
    "my-notify": {"type": "postRequest", "actions": [{"type": "shell", "shell": "true"}]}
  },
  "rules": [{"path": "mine.md"}]
}
EOF
check "install into an existing config" install_ --config-dir "$C"
check "  user hook and other keys kept" \
  jq -e '.hooks["my-notify"] and .defaultModel == "x/y" and .rules == [{"path": "mine.md"}]' "$C/config.json"
check "  one backup written" test "$(backups "$C")" = 1
check "second install is a no-op (no new backup)" install_ --config-dir "$C"
check "  no second backup" test "$(backups "$C")" = 1
check "  output says up to date" grep -q "already up to date" "$T/out.log"

# upsert: an older/edited eca-goal hook gets replaced, a removed one gets dropped
jq '.hooks["eca-goal-loop"].actions[0].timeout = 5 | .hooks["eca-goal-old-name"] = {"type": "chatStart", "actions": [{"type": "shell", "file": "/x/eca-goal-old.sh"}]}' \
  "$C/config.json" >"$T/c.json" && cp "$T/c.json" "$C/config.json"
sleep 1 # new backup name (timestamp has 1s resolution)
check "upsert over an edited eca-goal hook" install_ --config-dir "$C"
check "  timeout restored, stale eca-goal key removed, no duplicates" \
  jq -e '.hooks["eca-goal-loop"].actions[0].timeout == 1200000 and (.hooks | has("eca-goal-old-name") | not) and (.hooks | keys | length == 5)' "$C/config.json"

C=$T/foreign-key; mkdir -p "$C"
echo '{"hooks": {"eca-goal-loop": {"type": "postRequest", "actions": [{"type": "shell", "shell": "echo mine"}]}}}' >"$C/config.json"
cp "$C/config.json" "$T/orig.json"
check "refuses a foreign eca-goal-* hook key" bash -c "! '$REPO/install.sh' --no-schema --config-dir '$C'"
check "  config untouched" cmp -s "$C/config.json" "$T/orig.json"
check "  no files placed" test ! -e "$C/hooks/eca-goal-loop.sh"
check "--force takes it over" install_ --config-dir "$C" --force
check "  hook now points to eca-goal" jq -e '.hooks["eca-goal-loop"].actions[0].file | endswith("/eca-goal-loop.sh")' "$C/config.json"

C=$T/foreign-file; mkdir -p "$C/hooks"
echo '{}' >"$C/config.json"; echo 'echo mine' >"$C/hooks/eca-goal-loop.sh"
check "refuses a foreign file at a hook path" bash -c "! '$REPO/install.sh' --no-schema --config-dir '$C'"
check "  config untouched" test "$(cat "$C/config.json")" = '{}'

C=$T/dupes; mkdir -p "$C"
echo '{"a": 1, "b": 2, "a": 3}' >"$C/config.json"
check "refuses duplicate keys with different values" bash -c "! '$REPO/install.sh' --no-schema --config-dir '$C'"
echo '{"a": 1, "b": 2, "a": 1}' >"$C/config.json"
check "accepts duplicate keys with the same value" install_ --config-dir "$C"

C=$T/broken; mkdir -p "$C"
echo '{"a": 1,' >"$C/config.json"
check "refuses invalid JSON" bash -c "! '$REPO/install.sh' --no-schema --config-dir '$C'"
check "  broken file untouched" test "$(cat "$C/config.json")" = '{"a": 1,'

C=$T/dry; mkdir -p "$C"; echo '{}' >"$C/config.json"
check "dry-run succeeds" install_ --config-dir "$C" --dry-run
check "  dry-run wrote nothing" bash -c "test \"\$(cat '$C/config.json')\" = '{}' && test ! -e '$C/hooks' && test \$(ls '$C' | wc -l) = 1"

C=$T/copy; mkdir -p "$C"
check "install with --copy" install_ --config-dir "$C" --copy
check "  hooks are regular files" bash -c "test -f '$C/hooks/eca-goal-loop.sh' && test ! -L '$C/hooks/eca-goal-loop.sh'"
check "  commands are copied" test -f "$C/commands/eca-goal/goal.md"
check "reinstall as symlinks replaces the copies" install_ --config-dir "$C"
check "  now symlinks" test -L "$C/hooks/eca-goal-loop.sh"

C=$T/existing
echo 'mine' >"$T/mine.sh"; ln -s "$T/mine.sh" "$C/hooks/other.sh"
check "uninstall" install_ --config-dir "$C" --uninstall
check "  eca-goal hooks removed, user hook kept" test "$(hooks_of "$C")" = "my-notify "
check "  links removed" bash -c "test ! -e '$C/hooks/eca-goal-loop.sh' && test ! -e '$C/commands/eca-goal'"
check "  unrelated files kept" test -L "$C/hooks/other.sh"
check "uninstall again is a no-op" install_ --config-dir "$C" --uninstall

if [ "$SCHEMA_TESTS" = 1 ]; then
  echo "== installer + JSON schema"
  if curl -fsSL --max-time 30 https://eca.dev/config.json -o "$T/schema.json"; then
    C=$T/schema; mkdir -p "$C"
    echo '{"hooks": {"x": {"type": "postRequest", "actions": [{"type": "shell", "shell": "true"}]}}}' >"$C/config.json"
    check "install with schema validation (valid config)" \
      "$REPO/install.sh" --config-dir "$C" --schema-file "$T/schema.json" --strict-schema
    echo '{"chat": {"notAKey": true}}' >"$C/../schema-bad.json"; mkdir -p "$T/schema-bad"; mv "$C/../schema-bad.json" "$T/schema-bad/config.json"
    check "old schema errors do not block the install" \
      "$REPO/install.sh" --config-dir "$T/schema-bad" --schema-file "$T/schema.json"
    echo '{"chat": {"notAKey": true}}' >"$T/schema-bad/config.json"
    check "--strict-schema blocks when errors remain" \
      bash -c "! '$REPO/install.sh' --config-dir '$T/schema-bad' --schema-file '$T/schema.json' --strict-schema"
    check "  config untouched" test "$(cat "$T/schema-bad/config.json")" = '{"chat": {"notAKey": true}}'
  else
    echo "  skip (cannot download https://eca.dev/config.json)"
  fi
fi

echo "== hooks"
W=$T/ws; mkdir -p "$W/.eca/eca-goal"
LOOP=$REPO/hooks/eca-goal-loop.sh; CTX=$REPO/hooks/eca-goal-context.sh; CLAIM=$REPO/hooks/eca-goal-claim.sh
input() { jq -n --arg cwd "$W" --arg chat "${1:-chat-1}" --arg agent "${2-code}" \
  '{cwd: $cwd, chat_id: $chat, response: "did stuff", follow_up_active: false} + (if $agent == "" then {} else {agent: $agent} end)'; }
typed() { # typed CHAT TEXT -> what the preRequest hook sees when a human types TEXT
  jq -n --arg cwd "$W" --arg chat "$1" --arg p "$2" '{cwd: $cwd, chat_id: $chat, prompt: $p, hook_type: "preRequest"}' | "$CLAIM"; }
chat_start() { jq -n --arg cwd "$W" --arg chat "$1" --arg t "${2:-chatStart}" '{cwd: $cwd, chat_id: $chat, hook_type: $t}' | "$CTX"; }
goal() { # goal STATUS CHECK [JUDGE] -> as if chat-1 typed /goal and the agent wrote goal.md
  typed chat-1 "/goal test"
  write_goal "$@"
}
write_goal() {
  cat >"$W/.eca/eca-goal/goal.md" <<EOF
status: $1
iteration: 0
max_iterations: 3
judge: ${3:-off}
check: $2
---
## Objective
Test.
## Done when
- marker exists
## Progress
status: this line is body text and must never change
EOF
}
get() { sed -n "s/^$1: *//p" "$W/.eca/eca-goal/goal.md" | head -1; }
lget() { jq -r ".$1 // empty" "$W/.eca/eca-goal/loop.json"; }

G=$W/.eca/eca-goal
set_status() { (. "$REPO/hooks/eca-goal-lib.sh"; goal_set "$G/goal.md" status "$1"); } # header only
proof() { # proof [COMMAND] -> a valid proof for the one "Done when" item
  if [ -n "${1:-}" ]; then
    printf '## marker exists\nmethod: command\ncommand: %s\nevidence: it exits 0\nconfidence: high\n' "$1" >"$G/proof.md"
  else
    printf '## marker exists\nmethod: judgement\nevidence: I looked\nconfidence: medium\n' >"$G/proof.md"
  fi
}
claim() { proof "$@"; set_status claimed; } # the agent claims the goal
review() { printf 'verdict: %s\n- marker exists: ok\n' "$1" >"$G/review.md"; }

goal active "test -f marker"; sed -i 's/^max_iterations: 3$/max_iterations: 50/' "$G/goal.md"
check "/goal typed by a human -> this chat owns the goal" test "$(lget owner)" = chat-1
out=$(input | "$LOOP")
check "failing check -> followUp with the exit code" jq -e '.followUp | contains("exited 1")' <<<"$out"
check "  followUp says how to claim" jq -e '.followUp | contains("status: claimed") and contains("proof.md")' <<<"$out"
check "  iteration counted in loop.json and mirrored" test "$(lget iteration)/$(get iteration)" = 1/1
check "  body line untouched" grep -q '^status: this line is body text' "$G/goal.md"
check "  .gitignore created in the state dir" test "$(cat "$G/.gitignore")" = '*'
out=$(input chat-2 | "$LOOP")
check "another chat: no followUp, a visible notice" jq -e '(has("followUp") | not) and (.systemMessage | contains("owned by another chat"))' <<<"$out"
out=$(input chat-2 | "$LOOP")
check "  the notice is shown only once per chat" test -z "$out"
sed -i 's/^iteration: 1$/iteration: 0/' "$G/goal.md"
touch "$W/marker"
out=$(input | "$LOOP")
check "editing iteration in goal.md does not reset the budget" test "$(lget iteration)" = 2
check "passing check, no claim -> nudge to claim, no verification" jq -e '.followUp | contains("you have not claimed the goal yet")' <<<"$out"
check "  status stays active" test "$(get status)" = active
set_status claimed
out=$(input | "$LOOP")
check "claim without proof.md -> not accepted, format shown" jq -e '.followUp | contains("proof.md is missing") and contains("method: check | command | file-read | judgement")' <<<"$out"
check "  status active, not counted as a rejected claim" test "$(get status)/$(lget claim_rejects)" = active/
printf '## marker exists\nmethod: vibes\n## extra\nmethod: command\nevidence: x\n' >"$G/proof.md"; set_status claimed
out=$(input | "$LOOP")
check "bad proof -> each problem listed" jq -e '.followUp | contains("must be check, command, file-read or judgement") and contains("no `evidence:` line") and contains("needs at least one `command:` line")' <<<"$out"
printf -- '- second item\n' >>"$G/goal.md"; sed -i 's/^## Progress$/- second item\n## Progress/' "$G/goal.md"; claim
out=$(input | "$LOOP")
check "proof with fewer sections than Done when items -> not accepted" jq -e '.followUp | contains("1 `## ` sections, but goal.md has 2")' <<<"$out"
printf '## marker exists\nmethod: check\nevidence: the check tests it\n## second item\nmethod: command\ncommand: echo x >>%s/ran-count\nevidence: x\n## third\nmethod: command\ncommand: echo x >>%s/ran-count\nevidence: x\n' "$T" "$T" >"$G/proof.md"
sed -i 's/^## Progress$/- third item\n## Progress/' "$G/goal.md"; set_status claimed; rm -f "$T/ran-count"
out=$(input | "$LOOP")
check "method: check is accepted -> verification turn" jq -e '.followUp | contains("fresh reviewer")' <<<"$out"
check "  the reviewer confirms that the check tests check items" jq -e '.followUp | contains("For `check` items, read the check")' <<<"$out"
check "  a command listed for two items runs once" test "$(wc -l <"$T/ran-count")" = 1
check "  and counts once" jq -e '.followUp | contains("re-ran the 1 command")' <<<"$out"
set_status active; sed -i '/^- second item$/d; /^- third item$/d' "$G/goal.md"
jq '.audit_pending = false' "$G/loop.json" >"$T/l.json" && mv "$T/l.json" "$G/loop.json"   # undo the started verification
claim "test -f no-such-file"
out=$(input | "$LOOP")
check "claim with a failing proof command -> not accepted, back to work" jq -e '.followUp | contains("re-ran the commands in your proof") and contains("test -f no-such-file")' <<<"$out"
check "  NOT counted as a rejected claim, status active" test "$(lget claim_rejects)/$(get status)" = /active
check "  followUp says it does not count" jq -e '.followUp | contains("does not count as a rejected claim")' <<<"$out"
check "  the standing rules say: no need to pre-run the check" jq -e '.followUp | contains("You do not need to run the check or the proof commands yourself")' <<<"$out"
claim "test -f no-such-file"; out=$(input | "$LOOP")
check "  the same proof failure again -> stall warning" jq -e '.followUp | contains("WARNING: the same proof commands fail")' <<<"$out"
check "  stall_count 2, still no rejected claim" test "$(lget stall_count)/$(lget claim_rejects)" = 2/
claim "test -f no-such-file"; out=$(input | "$LOOP")
check "  third time -> paused stall" test "$(get status)/$(get paused_reason)" = paused/stall
typed chat-1 "/goal-resume" >/dev/null
echo old >"$G/review.md"; claim "test -f marker"
out=$(input | "$LOOP")
check "valid claim -> verification turn with a fresh reviewer" jq -e '.followUp | contains("fresh reviewer") and contains("eca__spawn_agent") and contains("re-ran the 1 command")' <<<"$out"
check "  reviewer sorts problems into blocking and minor" jq -e '.followUp | contains("BLOCKING:") and contains("MINOR:") and contains("Only blocking problems make an item `not-ok`")' <<<"$out"
check "  the reviewer is told what already passed, and not to re-run it" jq -e '.followUp | contains("already ran the check `test -f marker` (exit 0, ") and contains("and the 1 proof command(s) on this exact working tree") and contains("Do not re-run them")' <<<"$out"
check "  a fast check: no timeout advice" jq -e '.followUp | contains("use a timeout above") | not' <<<"$out"
check "  the reviewer gets the check output" jq -e '.followUp | contains("The last lines of the check output")' <<<"$out"
check "  lessons are about the repo, not the loop" jq -e '.followUp | contains("eca-goal-lessons.md") and contains("not about the goal loop")' <<<"$out"
check "  round 1: no history, no convergence rule" jq -e '.followUp | contains("review round 1") and (contains("Previous findings") | not)' <<<"$out"
check "  status auditing, verified no, audit_pending" test "$(get status)/$(get verified)/$(lget audit_pending)" = auditing/no/true
check "  old review.md removed" test ! -e "$G/review.md"
review pass
out=$(input | "$LOOP")
check "verification: review pass but no verified: yes -> rejected" jq -e '.followUp | contains("ended without `verified: yes`") and contains("Reviewer findings")' <<<"$out"
check "  status active, claim_rejects 1" test "$(get status)/$(lget claim_rejects)" = active/1
claim "test -f marker"; input | "$LOOP" >/dev/null
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"; review fail
out=$(input | "$LOOP")
check "verification: verified: yes but verdict fail -> rejected, not done" jq -e '.followUp | contains("does not say `verdict: pass`")' <<<"$out"
check "  claim_rejects 2" test "$(get status)/$(lget claim_rejects)" = active/2
claim "test -f marker"; input | "$LOOP" >/dev/null; review fail
out=$(input | "$LOOP")
check "  third rejection -> paused claims-rejected" test "$(get status)/$(get paused_reason)" = paused/claims-rejected
typed chat-1 "/goal-resume" >/dev/null
check "/goal-resume resets claim_rejects and removes review.md" test "$(lget claim_rejects)" = "" -a ! -e "$G/review.md"
claim "test -f marker"; input | "$LOOP" >/dev/null
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"; review pass
out=$(input | "$LOOP")
check "verification: verified: yes + verdict pass -> done" test "$(get status)" = "done"
check "  confirmed in loop.json" test "$(lget done_confirmed)" = true
check "  done message" jq -e '.systemMessage | startswith("Goal done")' <<<"$out"
out=$(input | "$LOOP")
check "confirmed done goal is ignored" test -z "$out"
check "  chatStart: silent for a confirmed done" test -z "$(chat_start chat-9)"
goal active "true"; sed -i '1a verified: yes' "$G/goal.md"; claim
input | "$LOOP" >/dev/null
check "stale verified: yes is reset when a verification starts" test "$(get verified)" = no
typed chat-1 "/goal next"
check "/goal removes an old proof.md" test ! -e "$G/proof.md"

echo "== hooks: review history, severity, re-check"
verify() { claim "test -f marker"; input | "$LOOP"; }   # a claim that passes the mechanical checks
goal active "test -f marker"; sed -i 's/^max_iterations: 3$/max_iterations: 50/' "$G/goal.md"; touch "$W/marker"
verify >/dev/null; review fail
out=$(input | "$LOOP")
check "failed verification keeps review-1.md" test -f "$G/review-1.md"
check "  followUp says so" jq -e '.followUp | contains("kept as .eca/eca-goal/review-1.md")' <<<"$out"
out=$(verify)
check "round 2: the reviewer gets the earlier review" jq -e '.followUp | contains("review round 2") and contains("the earlier reviews: .eca/eca-goal/review-1.md")' <<<"$out"
check "  round 2: previous findings and the convergence rule" jq -e '.followUp | contains("## Previous findings") and contains("must be either in something that changed")' <<<"$out"
printf 'verdict: pass\n## Items\n- marker exists: ok\n## Blocking\n- goal.md:3 wrong\n## Minor\n- none\n' >"$G/review.md"
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"
out=$(input | "$LOOP")
check "pass with a non-empty Blocking list -> rejected" jq -e '.followUp | contains("`## Blocking` list is not empty")' <<<"$out"
check "  review-2.md kept" test -f "$G/review-2.md"
typed chat-1 "/goal-resume" >/dev/null
check "/goal-resume keeps the review history" test -f "$G/review-1.md" -a -f "$G/review-2.md"
out=$(verify)
check "  round 3 after resume" jq -e '.followUp | contains("review round 3") and contains("review-2.md")' <<<"$out"
printf 'verdict: pass\n## Items\n- marker exists: ok\n## Blocking\n- none\n## Minor\n- README.md:3 typo\n' >"$G/review.md"
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"; rm -f "$W/marker"   # a "minor fix" broke the check
out=$(input | "$LOOP")
check "pass + verified, but the check fails now -> rejected, not done" jq -e '.followUp | contains("the check fails after the verification turn") and contains("exited 1")' <<<"$out"
check "  status active" test "$(get status)/$(lget done_confirmed)" = active/
touch "$W/marker"; verify >/dev/null
printf 'verdict: pass\n## Items\n- marker exists: ok\n## Blocking\n- none\n## Minor\n- README.md:3 typo\n' >"$G/review.md"
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"
out=$(input | "$LOOP")
check "pass, empty Blocking, only minor findings, check passes -> done" test "$(get status)/$(lget done_confirmed)" = done/true
typed chat-1 "/goal next" >/dev/null
check "/goal removes the review history" bash -c "! ls '$G'/review-*.md 2>/dev/null | grep -q ."

echo "== hooks: paused goal notice"
goal active "false"; sed -i 's/^max_iterations: 3$/max_iterations: 50/' "$G/goal.md"
input chat-1 "" | "$LOOP" >/dev/null   # a stopped turn -> paused user-stop
out=$(input | "$LOOP")
check "paused goal: the owning chat is told once how to go on" jq -e '.systemMessage | contains("paused (user-stop)") and contains("/goal-resume")' <<<"$out"
check "  not repeated" test -z "$(input | "$LOOP")"
check "  other chats are not told" test -z "$(input chat-7 | "$LOOP")"
typed chat-1 "/goal-pause" >/dev/null
check "  no notice after /goal-pause (manual)" test -z "$(input | "$LOOP")"

echo "== hooks: goals without a check command"
goal active ""
printf '## marker exists\nmethod: check\nevidence: x\n' >"$G/proof.md"; set_status claimed
out=$(input | "$LOOP")
check "method: check without a check command -> not accepted" jq -e '.followUp | contains("`method: check`, but goal.md has no check command")' <<<"$out"
check "  not counted as a rejected claim" test "$(get status)/$(lget claim_rejects)" = active/
out=$(input | "$LOOP")
check "no check -> work followUp, reviewer decides" jq -e '.followUp | contains("has no check command") and contains("status: claimed")' <<<"$out"
check "  still active" test "$(get status)" = active
claim
out=$(input | "$LOOP")
check "judgement-only claim, no check -> verification turn" jq -e '.followUp | contains("fresh reviewer") and contains("check `(none)`")' <<<"$out"
check "  nothing ran, so the reviewer is not told to skip anything" jq -e '.followUp | (contains("already ran") or contains("The last lines of the check output")) | not' <<<"$out"
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"; review pass
input | "$LOOP" >/dev/null
check "  reviewer pass -> done" test "$(get status)/$(lget done_confirmed)" = done/true
goal active "false"; claim
out=$(input | "$LOOP")
check "claim while the check fails -> back to work with the check output" jq -e '.followUp | contains("not accepted: the check fails") and contains("exited 1")' <<<"$out"
check "  not counted as a rejected claim" test "$(get status)/$(lget claim_rejects)" = active/
goal active "true"; claim; input | "$LOOP" >/dev/null   # -> auditing
set_status active; review fail
out=$(input | "$LOOP")
check "reopening the goal during the verification -> rejected with findings" jq -e '.followUp | contains("during the verification") and contains("verdict: fail")' <<<"$out"
check "  audit_pending cleared" test "$(jq -r .audit_pending "$G/loop.json")" = false

echo "== hooks: ownership and provenance"
rm -f "$W/.eca/eca-goal/loop.json"
write_goal active "false"; sed -i '1a chat_id: chat-1' "$W/.eca/eca-goal/goal.md"
out=$(input | "$LOOP")
check "no /goal typed: an invented chat_id in goal.md does NOT start the loop" jq -e '(has("followUp") | not) and (.systemMessage | contains("no chat owns it"))' <<<"$out"
check "  nothing counted" test "$(get iteration)" = 0
check "  chatStart gives the model nothing" test -z "$(chat_start chat-1)"
typed chat-1 "please do not /goal-resume" ; out=$(input | "$LOOP")
check "  a command in the middle of a prompt does not claim" test -z "$(lget owner)"
write_goal paused "false"; sed -i '1a paused_reason: stall' "$W/.eca/eca-goal/goal.md"
out=$(typed chat-5 "/goal-resume keep going")
check "/goal-resume typed by a human -> status active" test "$(get status)" = active
check "  and the goal is injected into that prompt" jq -e '.additionalContext | contains("now owns the goal") and contains("## Objective")' <<<"$out"
check "  paused_reason cleared, owner = that chat" test "$(get paused_reason)/$(lget owner)" = /chat-5
out=$(input chat-5 | "$LOOP")
check "  the loop runs in the new chat" jq -e '.followUp | contains("Goal not met yet")' <<<"$out"
check "  postCompact in another chat: silent" test -z "$(chat_start chat-1 postCompact)"
typed chat-5 "/goal-pause lunch"
check "/goal-pause typed by a human -> paused, manual" test "$(get status)/$(get paused_reason)" = paused/manual
out=$(input chat-5 | "$LOOP")
check "  no follow-up while paused" test -z "$out"

typed chat-1 "/goal x"; write_goal active "false"
input | "$LOOP" >/dev/null
sed -i 's/^status: active$/status: done/' "$W/.eca/eca-goal/goal.md"
check "agent wrote status: done -> other chat is told it is NOT confirmed" jq -e '.systemMessage | contains("never confirmed")' <<<"$(input chat-9 | "$LOOP")"
out=$(input | "$LOOP")
check "  the loop does not accept it: check fails -> back to work" jq -e '.followUp | contains("without the loop confirming it") and contains("Goal not met yet")' <<<"$out"
check "  status active again" test "$(get status)" = active
typed chat-1 "/goal x"; write_goal active "true"; claim
input | "$LOOP" >/dev/null   # -> verification
set_status done
out=$(input | "$LOOP")
check "agent wrote status: done during the verification -> rejected, not done" jq -e '.followUp | contains("without the loop confirming it") and contains("did not confirm")' <<<"$out"
check "  status active, not confirmed" test "$(get status)/$(lget done_confirmed)" = active/
typed chat-1 "/goal x"; write_goal active "true"; proof
sed -i 's/^status: active$/status: auditing/; 1a verified: yes' "$G/goal.md"
out=$(input | "$LOOP")
check "agent wrote status: auditing + verified: yes itself -> NOT done" test "$(get status)" = auditing
check "  the loop ran its own checks (iteration counted)" test "$(lget iteration)" = 1
check "  treated as a claim: a real verification starts, and says why" jq -e '.followUp | contains("was set by you, not by the loop") and contains("fresh reviewer")' <<<"$out"
check "  verified is no again" test "$(get verified)" = no
check "  audit_pending recorded in loop.json" test "$(lget audit_pending)" = true
sed -i 's/^verified: no$/verified: yes/' "$G/goal.md"; review pass
out=$(input | "$LOOP")
check "  verified: yes + pass in the loop-started verification -> done" test "$(get status)/$(lget done_confirmed)" = done/true
typed chat-1 "/goal x"; write_goal auditing "false"; proof; sed -i '1a verified: yes' "$G/goal.md"
out=$(input | "$LOOP")
check "self-set auditing with a failing check -> rejected, back to work" jq -e '.followUp | contains("was set by you, not by the loop") and contains("Goal not met yet")' <<<"$out"
check "  status active" test "$(get status)" = active

write_goal "done" "false"; typed chat-1 "/goal new thing"
out=$(input | "$LOOP")
check "a finished goal.md from before /goal is not revived" jq -e 'has("followUp") | not' <<<"$out"
check "  status stays done" test "$(get status)" = "done"

echo "== hooks: stop conditions"
rm -f "$W/marker"; goal active 'date +%s%N; false'
for _ in 1 2 3; do input | "$LOOP" >/dev/null; done
out=$(input | "$LOOP")
check "max_iterations -> paused" test "$(get status)" = paused
check "  paused_reason budget" test "$(get paused_reason)" = budget
check "  paused message" jq -e '.systemMessage | contains("max_iterations")' <<<"$out"

goal active "echo same; false"
out1=$(input | "$LOOP"); out2=$(input | "$LOOP")
check "stall: first failure has no warning" not jq -e '.followUp | contains("WARNING")' <<<"$out1"
check "stall: second identical failure warns" jq -e '.followUp | contains("exactly the same")' <<<"$out2"
check "  stall_count 2" test "$(lget stall_count)" = 2
out=$(input | "$LOOP")
check "stall: third identical failure -> paused" test "$(get status)" = paused
check "  paused_reason stall" test "$(get paused_reason)" = stall

goal active 'echo "step $(cat n)"; false'
echo 1 >"$W/n"; input | "$LOOP" >/dev/null; echo 2 >"$W/n"; input | "$LOOP" >/dev/null; echo 3 >"$W/n"; input | "$LOOP" >/dev/null
check "changing output is not a stall" test "$(get status)" = active
check "  stall_count stays 1" test "$(lget stall_count)" = 1

goal active "test -f never-there"
for _ in 1 2 3; do input | "$LOOP" >/dev/null; done
check "a silent failing check is never a stall" test "$(get status)" = active
check "  a fast check: time recorded, no slow-check hint" test "$(lget check_secs)" = 0
goal active "sleep 1; echo slow; false"
out=$(input | ECA_GOAL_SLOW_CHECK=0 "$LOOP")
check "slow check -> hint with the time, keep it correct" jq -e '.followUp | test("The check took [0-9]+s") and contains("without sacrificing correctness")' <<<"$out"
check "  time recorded in loop.json" test "$(lget check_secs)" -ge 1
out=$(input | ECA_GOAL_SLOW_CHECK=0 "$LOOP")
check "  the hint is given only once per goal" jq -e '.followUp | contains("The check took") | not' <<<"$out"
goal active "sleep 1; true"; claim
out=$(input | ECA_GOAL_SLOW_CHECK=0 "$LOOP")
check "slow check at a claim -> no hint in the verification turn" jq -e '(.followUp | contains("fresh reviewer")) and (.followUp | contains("The check took") | not)' <<<"$out"
check "  the hint is kept for a later work turn" test "$(lget slow_warned)" = ""

goal active "no-such-command-eca-goal"
out=$(input | "$LOOP")
check "check not found (127) -> environment hint" jq -e '.followUp | contains("cannot run (exit 127")' <<<"$out"
out=$(input | "$LOOP")
check "  second time -> paused" test "$(get status)" = paused
check "  paused_reason check-broken" test "$(get paused_reason)" = check-broken

goal active "echo SHOULD-NOT-RUN > $T/ran"
out=$(input chat-1 "" | "$LOOP")
check "stopped turn (no agent in input) -> paused" test "$(get status)" = paused
check "  paused_reason user-stop" test "$(get paused_reason)" = user-stop
check "  check not run" test ! -e "$T/ran"

goal active "false"
out=$(input | "$LOOP")
check "followUp tells the agent to work autonomously" jq -e '.followUp | contains("Work autonomously") and contains("needs-human")' <<<"$out"
check "followUp suggests parallel subagents for research" jq -e '.followUp | contains("eca__spawn_agent") and contains("in parallel") and (contains("single next step") | not)' <<<"$out"
check "followUp forbids commits unless asked, and any push" jq -e '.followUp | contains("Do not commit unless the goal text asks for it. Never push.")' <<<"$out"

echo "== hooks: judge"
goal active "true" local; claim
out=$(input | ECA_GOAL_JUDGE_URL="" "$LOOP")
check "judge: local without URL -> claim rejected" jq -e '.followUp | contains("ECA_GOAL_JUDGE_URL is not set")' <<<"$out"
check "  status active" test "$(get status)" = active

judge_server() { # judge_server MET PORTFILE -> one-shot fake OpenAI endpoint
  python3 - "$1" "$2" <<'PY' &
import json, sys, http.server
met = sys.argv[1] == "true"
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        body = json.dumps({"choices": [{"message": {"content": json.dumps({"met": met, "reason": "fake judge"})}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_port))
s.handle_request()
PY
  for _ in $(seq 50); do [ -s "$2" ] && break; sleep 0.1; done
}
if command -v python3 >/dev/null && command -v curl >/dev/null; then
  goal active "true" local; claim; rm -f "$T/port"; judge_server false "$T/port"
  out=$(input | ECA_GOAL_JUDGE_URL="http://127.0.0.1:$(cat "$T/port")" "$LOOP")
  check "judge says not met -> followUp with reason" jq -e '.followUp | contains("Judge says: fake judge")' <<<"$out"
  goal active "true" local; claim; rm -f "$T/port"; judge_server true "$T/port"
  out=$(input | ECA_GOAL_JUDGE_URL="http://127.0.0.1:$(cat "$T/port")" "$LOOP")
  check "judge says met -> verification" test "$(get status)" = auditing
  wait
fi


echo "== hooks: context"
goal active "true"
out=$(chat_start chat-1)
check "context hook injects the goal in the owning chat" jq -e '.additionalContext | contains("## Objective")' <<<"$out"
check "  also after compaction" jq -e '.additionalContext | contains("## Objective")' <<<"$(chat_start chat-1 postCompact)"
check "  other chat: nothing" test -z "$(chat_start chat-2)"
write_goal paused "true"
check "context hook ignores paused goals" test -z "$(chat_start chat-1)"
rm -rf "$W/.eca"
check "hooks are silent without a goal file" test -z "$(input | "$LOOP")$(chat_start chat-1)$(typed chat-1 '/goal-resume')"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
