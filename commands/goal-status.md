---
description: "eca-goal: show the state of the goal loop."
---
Read `.eca/eca-goal/goal.md` and `.eca/eca-goal/loop.json` (the loop's own bookkeeping; it may be missing). Report in a few short lines:
- status (and `paused_reason` if paused). `claimed` means the agent claims the goal is met and the loop verifies it next; `auditing` means the verification turn runs. If status is `done`, say whether `loop.json` has `done_confirmed: true`; if not, say clearly: "done, but NOT confirmed by the loop".
- which chat owns the goal (`owner` in loop.json; "no owner" if missing).
- iteration (from loop.json) / max_iterations, `stall_count` if above 0, and `claim_rejects` if above 0.
- the check command (or "none: a reviewer judges done-ness"), which "Done when" items look met, and the last Progress entry.
- if `.eca/eca-goal/review.md` exists: its verdict and its blocking findings, in one or two lines. If `.eca/eca-goal/review-<N>.md` files exist, say how many review rounds failed so far.
Do not change any file. If goal.md does not exist, say that no goal is set.
