---
description: "eca-goal: start a goal loop. The agent works until its claim that the goal is met is verified."
---
Set up an autonomous goal for this workspace.

Goal from user: $ARGUMENTS

1. If `.eca/rules/eca-goal-lessons.md` exists, read it first. It holds lessons from earlier goals in this repo.
2. If `.eca/eca-goal/goal.md` exists with `status: active`, `claimed` or `auditing`, stop and ask me whether to replace it.
3. Turn the goal into concrete "Done when" items. Each item must be specific enough that a skeptical reviewer, who did not see this chat, can decide yes or no by looking at the repo. "The docs are better" is too vague; "every public function in `api/` has a docstring with an example" is fine. If an item stays vague, ask me short questions until it is concrete. Do not write any file and do not start work before that. If the request is a list of independent tasks, tell me that one goal per task works better, and propose the first one.
4. Try hard to find ONE shell command that proves the end state (tests, build, lint, grep...). It must exit 0 only when the goal is met. A check is the strongest proof, so prefer goals and items that a command can check. Make the check strict:
   - **Guards:** ask yourself what must NOT change or break (other tests, public APIs, files outside scope) and put that into the check too, e.g. `git diff --quiet -- src/legacy/ && ./run-tests.sh`.
   - **Do not call other goal checks from this check.** Each one runs its own test suite again, so the cost doubles with each goal. Run the test suite and the linter **once**. To keep the guards of earlier goals, copy their cheap asserts (greps, file checks), or call them with a flag that skips their suite. When a repo has several goal checks, keep one shared guard script (for example `scripts/guards.sh`: the full test suite and the linter, each run once), and call it once from each goal check.
   - **No empty passes:** the check must fail if it examined too little (e.g. assert a minimum number of tests or items found), so a broken extraction cannot pass by accident.
   - **Show progress:** the check should print what is still missing (e.g. names of failing tests, a count of open items). The loop uses the output to see progress; identical output 3 times in a row pauses the goal as stalled.
   - **Fast and narrow:** prefer the smallest command that proves the goal. It runs after every turn, at every claim and before done. Target: about a minute.
   If a command can prove only part of the goal, check that part. If no command can prove any of it (the goal is "fluid", e.g. docs or design work), leave `check:` empty. Then tell me in one line: "No check command: a reviewer will judge done-ness." Run the check once now (if there is one) to see the baseline.
5. Create the directory `.eca/eca-goal/`. If `.eca/eca-goal/.gitignore` does not exist, create it with the single line `*`. This directory holds only the loop's state. Everything the goal produces (scripts, tests, docs, check helpers) goes into the repo in its normal place, never into `.eca/eca-goal/`: that directory is git-ignored, so files there would be lost.
6. Write `.eca/eca-goal/goal.md` in exactly this format. Keep the header keys first, one per line, and end the header with a line that is exactly `---`:

```
status: active
iteration: 0
max_iterations: 50
judge: off
verified: no
paused_reason:
check: <the command, on one line, or empty>
---
## Objective
<one paragraph>
## Done when
- <concrete item>
## Plan
- [ ] <step>
## Progress
## Notes
```

Keep `judge: off` unless I asked for the external LLM judge (it needs `ECA_GOAL_JUDGE_URL`, and it sees only the text of your proof, not the files). A fresh reviewer checks every claim anyway. Raise `max_iterations` for big goals: one iteration is one turn.
7. Start work at once on the first plan step. After each step, update Progress.

Rules for the whole goal:
- Work autonomously. When you face a choice you can make yourself, pick the most reasonable option, write it under Notes with a one-line reason, and continue. Do not ask me for confirmation.
- Delegate independent research to subagents with `eca__spawn_agent`: `explorer` to find files and read code (read-only), `general` for multi-step side tasks. When the parts are independent (for example, several screens or modules to map), start them in the same response so they run in parallel. Give each one a precise task and ask for a short result. Keep all edits, and the change -> check -> fix cycle, in the main agent.
- Set `status: paused` and `paused_reason: needs-human` ONLY when you need something only a human can give: credentials, access, an irreversible or outward-facing action, or requirements that conflict.
- Do not commit unless the goal text above explicitly asks for commits. Never push, not even when commits are allowed. Leave your changes in the working tree for me.
- Do not change the `check` line to make it pass. Change it only if the check itself is wrong, and write why under Notes.
- **Claiming the goal.** At the end of each turn, ask yourself: is every "Done when" item met? When yes, write `.eca/eca-goal/proof.md`, set `status: claimed`, and end your turn. The proof has one section per "Done when" item:
  ```
  ## <the Done when item>
  method: check | command | file-read | judgement
  command: <one shell line that exits 0 only if the item is met; repeat the line for more; method command only>
  evidence: <what you saw: command output, file:line, or your reasoning>
  confidence: high | medium | low
  ```
  Use `check` when the goal check proves the item: the loop runs the check anyway, so it runs nothing extra, and the reviewer confirms that the check really tests the item. Use `command` for a cheap command that the check does not cover (a grep, one focused test): the loop re-runs every `command:` line itself, so do not repeat what the check already runs. Use `file-read` when the proof is in specific files, and `judgement` only when nothing else works. Be honest about `confidence`.
- The loop then verifies the claim: it checks the proof format, runs the check and the proof commands, and starts a verification turn with a fresh reviewer. If anything fails, you get the reason and go back to work. A failing check or proof command costs one turn, not a rejected claim, so you do not need to run them yourself just before you claim. A rejected claim is a failed verification (or a judge "no"). After 3 rejected claims the goal pauses, so claim only when you really believe it is done.
- The reviewer sorts problems into **blocking** (an item is not met, a check is weakened or broken, the proof claims something false) and **minor** (wrong numbers or wording in prose, outdated comments, style). Only blocking problems fail the claim. When a claim is rejected, the review is kept as `.eca/eca-goal/review-<N>.md`, and the next reviewer first checks whether you fixed those findings.
- Never set `status: auditing` or `status: done` yourself. Set `verified: yes` only in the verification turn, and only when the reviewer says `verdict: pass` with no blocking findings. The loop runs the check once more, then marks the goal done.
- Never create or edit `.eca/eca-goal/loop.json`. The loop owns it.
