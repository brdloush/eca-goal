# Writing goals

## Usage tips

**Turn on trust mode** (the toggle in your editor, or `"chat": {"defaultTrust": true}`), or allow the tools the agent needs in `toolCall.approval`. If ECA asks you to approve a tool call, the loop waits for you.

To continue a goal in a fresh chat (for example after a handoff), type `/goal-resume` in the new chat. The new chat takes ownership, and the goal is injected into that prompt.

You must **type** the command yourself. Asking the agent in plain words ("please resume the goal") does not claim the goal.

## The state files

`.eca/eca-goal/` holds these files:

| File | Written by | What |
|---|---|---|
| `goal.md` | the agent and you | the goal and its state (below) |
| `proof.md` | the agent, when it claims | why it thinks each item is met ([The proof](#the-proof)) |
| `review.md` | the agent, in the verification turn | the fresh reviewer's answer, starting with `verdict: pass` or `verdict: fail` ([The review](#the-review)) |
| `review-<N>.md` | the hooks, when a verification fails | earlier reviews (round N); the next reviewer checks them first |
| `loop.json` | only the hooks | owner, counters, the time of the last check run, "done confirmed" |

`/goal` removes an old `proof.md`, `review.md` and `review-<N>.md`. `/goal-resume` removes only `review.md`, so the review history survives a resume. A `.gitignore` with `*` keeps all of them out of git. **Everything the goal produces (scripts, tests, check helpers) belongs in the repo, not in this directory**, because files there are never committed. `/goal` tells the agent so. You do not have to edit your `.gitignore`. Keep `.eca/rules/eca-goal-lessons.md` in git if you want to share the lessons.

## goal.md

```
status: active          # active | claimed | auditing | paused | done
iteration: 0            # mirror of loop.json, for you to read; editing it has no effect
max_iterations: 50
judge: off              # off | local
verified: no            # the agent sets "yes" in the verification turn, if the reviewer says pass
paused_reason:          # why the loop paused (see [How it works](how-it-works.md#autonomy-and-when-it-stops))
check: git diff --quiet -- src/legacy/ && ./gradlew test --tests '*Auth*'   # may be empty
---
## Objective
## Done when
- ...
## Plan
## Progress
## Notes
```

`claimed` is set by the agent. `auditing` and `done` are set only by the loop. The hooks read and write only the header (the lines before `---`). Optional keys: `stall_limit`, `claim_limit`.

You can edit the file by hand at any time. Decisions you make while a goal runs belong in `goal.md` (for example under Notes), not only in the chat: the agent re-reads it every turn, and it survives compaction and new chats.

## The proof

When the agent claims the goal, `proof.md` has one section per "Done when" item:

```
## all tests in test/auth pass
method: check
evidence: the goal check runs test/auth: 42 tests, 0 failures
confidence: high

## every public function in api/ has a docstring
method: command
command: ./scripts/check-docstrings.sh api/
evidence: the script lists 0 functions without a docstring (42 checked)
confidence: high

## the README explains the retry option
method: file-read
evidence: README.md:120-140, section "Retries", with an example
confidence: medium
```

| `method` | Use it when | What the loop does |
|---|---|---|
| `check` | the goal check proves the item | nothing extra: the hook runs the check anyway. The reviewer confirms that the check really tests the item |
| `command` | a cheap command that the check does not cover proves the item (a grep, one focused test) | the hook re-runs each `command:` line; one failure sends the agent back to work |
| `file-read` | the proof is in specific files | the reviewer reads those files |
| `judgement` | nothing else works | the reviewer judges it |

Prefer `check` over a `command:` that repeats what the check already runs (the test suite, an earlier goal's check): every `command:` line runs again at every claim. The hook runs a command that is listed for several items only once per claim.

The hook checks the format: at least as many sections as "Done when" items, a valid `method:` and an `evidence:` line in each, at least one `command:` line for `method: command`, and a check command in `goal.md` for `method: check`. `confidence` is for the reviewer and for you.

## The review

In the verification turn, the fresh reviewer writes its answer in this format, and the agent saves it unchanged to `review.md`:

```
verdict: pass | fail
## Previous findings        (review round 2 and later)
- <an earlier blocking finding>: fixed | not fixed — <reason>
## Items
- <Done when item>: ok | not-ok — <reason>
## Blocking
- <place>: <problem> — fix: <fix>
## Minor
- none
## Weak points
- <matters of taste or scope>
```

- **Blocking:** a "Done when" item is not met, a check is weakened or broken, or the proof claims something false. `verdict: pass` is allowed only when this list is empty (`- none`). The hook checks this: a pass with blocking findings is rejected.
- **Minor:** a wrong number or wording in prose, an outdated comment, style. Minor findings never fail the verdict. On a pass, the agent may fix them in prose, docs and comments, and lists the rest in its final summary.
- **Weak points:** matters of taste, and problems outside the "Done when" items.

The hook reads only the `verdict:` line and the `## Blocking` list. The rest is for the agent, the next reviewer, and you.

## Writing a good check

The check is the strongest proof, so its quality matters most. `/goal` asks the agent to follow these rules, and you can check them in `goal.md`:

- **Put the guards in the check.** A rule like "do not change the legacy code" is invisible to the loop unless the check tests it: `git diff --quiet -- src/legacy/ && ./run-tests.sh`. Without guards, an agent can reach the exit code by a shortcut.
- **Do not call other goal checks from the check.** When goals follow each other in one repo, the easy guard is "the checks of the earlier goals still pass". But each of those checks runs the test suite again, and if each new check calls all earlier ones, the cost doubles with every goal (1, 2, 4, 8, 16 suite runs). Run the test suite and the linter **once**. Keep the guards of earlier goals by copying their cheap asserts (greps, file checks), or call them with a flag that skips their suite. For a repo with several goal checks, keep one shared guard script (for example `scripts/guards.sh`: the full test suite and the linter, each run once), and call it once from each goal check.
- **No empty passes.** The check must fail if it examined too little, for example if it found fewer tests or items than expected. Otherwise a broken search can pass by accident.
- **Show progress.** Print what is still missing (failing test names, a count of open items). Stall detection compares the output, so a check whose output changes with progress never stalls by mistake.
- **Fast and narrow.** It runs after every turn, at every claim and before done. Target: about a minute.
- **One goal per task.** A list of independent tasks does not fit one exit code or one review. Run one goal per task, each with its own check.
- **Partial is fine.** If a command can prove only part of the goal, check that part. The reviewer handles the rest.

For goals that no command can prove, see [Hard, mixed and fluid goals](how-it-works.md#hard-mixed-and-fluid-goals).
