# How it works

The loop diagram is in the [README](../README.md#how-it-works).

eca-goal uses only standard ECA features: custom commands and hooks. You do not need a fork or a plugin.

## The steps

1. When you type `/goal <text>`, a **`preRequest` hook** (`eca-goal-claim.sh`) makes the current chat the owner of the goal. Then the command asks the agent to turn your text into concrete **"Done when"** items, and to find **one shell command** that exits `0` only when the goal is met. If no command can prove the goal, the `check` stays empty and the agent tells you so. The agent writes the state to `.eca/eca-goal/goal.md` and starts the work.
2. **Work phase.** After each turn of the owning chat, the **`postRequest` hook** (`eca-goal-loop.sh`) runs the check (if there is one):
   - **Check fails:** the hook starts a new turn (`followUp`) with the last 60 lines of output: "do the next step, update Progress".
   - **Check passes, or there is no check:** the hook starts a new turn: "continue, or claim the goal if every item is met".
3. **Claim.** When the agent believes every "Done when" item is met, it writes `.eca/eca-goal/proof.md` (one section per item, see [The proof](writing-goals.md#the-proof)) and sets `status: claimed`.
4. **Mechanical checks.** On a claim, the hook checks, in this order:
   1. the proof format: one section per item, a valid `method:`, `evidence:`, and `command:` lines where needed. A bad format is sent back with the list of problems (this does not count as a rejected claim);
   2. the check command;
   3. every `command:` line of the proof, run by the hook itself;
   4. the optional LLM judge. It gets only text (the items, the proof, the check output, the agent's last message): no files, no tools, no tool calls from the chat; see [Configuration](configuration.md#optional-llm-judge).

   If one of them fails, the claim is **rejected**: the agent gets the reason and goes back to work.
5. **Verification turn.** If all mechanical checks pass, the hook starts one verification turn. The agent must start **one fresh reviewer** subagent (`eca__spawn_agent`, `general`). The reviewer gets only the Objective, the "Done when" items, the proof and its own earlier reviews, not the chat history. It inspects the repo itself, gives `ok` / `not-ok` per item, and looks for concrete errors in what the goal produced (a wrong fact, a wrong `file:line` reference, a broken example, code that does not work). It sorts every problem into one of two classes:
   - **Blocking:** a "Done when" item is not met, a check is weakened or broken, or the proof claims something false. Only these make an item `not-ok` and fail the verdict.
   - **Minor:** a wrong number or wording in prose, an outdated comment, style. These are listed, but they do not fail the verdict.

   Matters of taste and problems outside the "Done when" items are weak points. The agent writes the answer to `.eca/eca-goal/review.md` (see [the review format](writing-goals.md#the-review)). On a pass, it may fix the minor findings in the same turn, but only in prose, docs and comments.
6. **Done.** The goal is `done` only if the verification turn ends with `verified: yes` in `goal.md`, `review.md` says `verdict: pass` with an empty `## Blocking` list, **and** the check still passes (the hook runs it once more, in case a minor fix broke something). Otherwise the claim is rejected and the reviewer's findings go back to the agent. After 3 rejected claims (`claim_limit`), the goal pauses.
7. **Later review rounds.** A rejected review is kept as `.eca/eca-goal/review-<N>.md`. The next reviewer gets these files and starts with `## Previous findings`: for each earlier blocking finding, `fixed` or `not fixed`. From round 2 on, a **new** blocking finding must be in something that changed since the earlier review, or serious (an item is not met, a check is broken or weakened, the proof claims something false). Parts that were already reviewed and did not change get minor findings only. So the review converges: fresh eyes find real problems, but the reviewer does not invent a new reason to fail every round. The history survives `/goal-resume`; `/goal` removes it.
8. At the end, the agent writes 1–5 lessons for this repo to `.eca/rules/eca-goal-lessons.md`. ECA loads every file in `.eca/rules/` as a rule, and `/goal` reads the lessons first. This is how the loop gets better over time.
9. The **`chatStart` and `postCompact` hooks** (`eca-goal-context.sh`) put the goal back into the context of the owning chat when it starts or resumes, and after compaction. A new chat gets the goal when you type `/goal-resume` in it.

## Hard, mixed and fluid goals

| Goal | Example | What decides |
|---|---|---|
| **Hard** | "all tests in `test/auth` pass" | The check command. The reviewer only confirms that the proof commands really test the items. |
| **Mixed** | "refactor X, tests stay green, the code is easier to read" | The check proves the hard part. The reviewer judges "easier to read". |
| **Fluid** | "every public function in `api/` has a docstring with an example" | No check. The proof and the reviewer decide. |

A fluid goal ends with "a fresh reviewer agreed", not "a test proved it". That is fine for docs and cleanup work. For correctness work, write a check.

Even fluid goals need **concrete** "Done when" items. "The docs are better" is too vague; the reviewer can only be as strict as the items are. `/goal` asks you questions until each item is concrete, but it does not require that a script can check it.

## Autonomy, and when it stops

eca-goal is built to keep working without you. The agent is told to make the choices it can make itself, write each one under Notes with a one-line reason, and continue. It is also told to hand independent research to subagents (`eca__spawn_agent`: `explorer`, `general`), in parallel when the parts are independent. This keeps the main chat small during long goals. Edits and the change → check → fix cycle stay in the main agent. It pauses (`paused_reason: needs-human`) only for things only a human can give: credentials, access, an irreversible or outward-facing action, or requirements that conflict.

The loop stops by itself only when continuing is useless. The reason goes into `paused_reason`:

| `paused_reason` | When |
|---|---|
| `stall` | The check failed 3 times in a row with exactly the same exit code and output (`stall_limit`, default 3). After the 2nd time the agent gets a warning to try a different approach. A check that prints nothing is never counted as a stall. |
| `claims-rejected` | 3 claims were rejected (`claim_limit`, default 3): a failing check or proof command, a judge "no", or a failed verification. The goal is probably unclear or too hard. Read `review.md`, sharpen the "Done when" items, then `/goal-resume`. |
| `check-broken` | The check command cannot run (exit 126 / 127: not executable / not found) 2 times in a row. After the 1st time the agent is told to fix the environment. |
| `budget` | `max_iterations` (default 50) is reached. |
| `user-stop` | You stopped a turn in the editor. |
| `needs-human` | The agent needs you (set by the agent). |
| `manual` | You ran `/goal-pause`. |

`/goal-resume` clears the reason, the counters (also the rejected claims) and `review.md`, and continues.

A goal without a check has no stall detection: there is no output to compare. `max_iterations` and `claim_limit` still stop it.

## Safety rails

- **`max_iterations`** (default 50). One iteration is one turn, not time. For a big overnight goal, raise it in `goal.md`.
- **Only you start, resume or pause a goal.** A `preRequest` hook sees the raw text you type, before ECA expands a slash command. When you type `/goal` or `/goal-resume`, it records the current chat as the owner in `.eca/eca-goal/loop.json`. `/goal-resume` and `/goal-pause` also change the status mechanically. The agent cannot type commands, so it cannot claim or resume a goal.
- **Hook-owned bookkeeping.** `loop.json` holds the owner, the iteration counter, the stall counters, the rejected-claim counter, whether a verification started by the loop is pending, and "done confirmed". Only the hooks write it. Editing `goal.md` (an invented `chat_id`, a reset `iteration`) has no effect on the loop.
- **Never silent.** When the loop does not run in a chat (no owner, or another chat owns the goal), it says so once in that chat, with the fix (`/goal-resume`). When the goal is paused, the owning chat is told once, with the reason: for example after a reboot, when a stopped turn paused the goal. Not after `/goal-pause`: you just typed it.
- **Stop = pause.** If you stop a turn in the editor, the goal changes to `paused`, and the check does not run.
- **No commits unless asked, never push.** The agent leaves its changes in the working tree for you. It commits only if your `/goal` text explicitly asks for it, and it never pushes.
- **The claim only starts the checks.** The agent may set `status: claimed`, but that never finishes the goal. Only a verification turn that the loop started, after all mechanical checks passed, and that ends with `verified: yes`, `verdict: pass` with no blocking findings, and a check that still passes, makes the goal `done`. The loop records that in `loop.json`.
- **No shortcuts.** If the agent writes `status: auditing` itself, the loop treats it as a claim and runs all checks. If it writes `status: done` itself, the loop does not accept it and sends it back to work. A `done` that the loop never confirmed is reported as such.
- **The loop re-runs the proof.** Every `command:` line in `proof.md` is run by the hook, not trusted from the agent's report. The reviewer also checks that these commands really test the item (not `true`).
- **Independent reviewer.** The reviewer is a fresh subagent without the chat history. It did not do the work, so it is less biased than the agent checking itself. The hook cannot prove that the agent really started a subagent: this part depends on the model following the prompt.
- **The agent can pause itself** (`status: paused`) when it needs you.
- The optional LLM judge can only make the loop **stricter**: it runs only on a claim, after the check and the proof commands passed. It cannot read files, so it is no replacement for the reviewer.

## Security

eca-goal runs shell commands on your machine. Know what runs, and who wrote it.

- **The hook runs commands without ECA's tool approval.** The `check:` line in `goal.md` and every `command:` line in `proof.md` are written by the agent. The `postRequest` hook runs them with `bash -c`, in the workspace, as your user. ECA does not ask you first, even when trust mode is off. So a goal gives the agent a way to run commands that you do not approve one by one. Read the `check:` line after `/goal` writes it, and use eca-goal only in repos and with models you trust.
- **Untrusted repos.** A cloned repo can contain its own `.eca/eca-goal/goal.md`. The loop does not run it by itself: a chat must own the goal, and only a typed `/goal` or `/goal-resume` sets the owner. But if you type `/goal-resume` in such a repo, its `check:` runs. Read `goal.md` first. (ECA itself also loads `.eca/` files from the repo, for example the rules in `.eca/rules/`.)
- **Command output goes to the agent.** The last lines of the check and proof output are sent back to the agent as a follow-up. Do not print secrets in a check.
- **The optional judge sends data out.** With `judge: local`, the hook sends the "Done when" items, the proof, the check output and the agent's last message to `ECA_GOAL_JUDGE_URL`. Point it only at an endpoint you trust.
- **The installer** changes only eca-goal's own hooks in `config.json`, and keeps a backup. Its schema check can run `npx` to download `ajv-cli` from npm; use `--no-schema` or a local `python3-jsonschema` to avoid that.

## Limits

- **The check runs inside the hook, synchronously.** The chat waits while it runs. The hook timeout is 20 minutes, and the check timeout is 15 minutes. Use a narrow, fast check when you can (for example one test class, not the full suite).
- Each follow-up turn adds the check output to the chat. The context grows with each iteration. Compaction works: the goal is injected again after it.
- `/goal` itself depends on the model following the command prompt. The hooks are tested; the model's behavior is not. This includes starting a real reviewer subagent in the verification turn: the hook checks `review.md`, but it cannot see who wrote it.
- A claim costs at least one extra turn (the verification), plus a reviewer subagent. A hard goal also gets one "continue, or claim" turn after the check first passes, if the agent did not claim in the same turn.
- `iteration` counts every turn of the owning chat while the goal is active, including turns that you type. Turns while the goal is paused do not count.
