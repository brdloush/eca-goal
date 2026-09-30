# Idea: general rules for soft goals

Status: **not built**. A plan to pick up later.

## Why

Fluid goals ("figure out X", "improve Y") have no natural check command. Today `/goal` only says "make the items concrete". A real Claude Code `/goal` session showed better habits:

- it turned a fluid goal into a fixed list of items, each needing one firm answer backed by checked facts;
- it named what was out of scope ("no code, no moved files");
- it allowed honest gaps ("if a fact can't be checked, name the gap in one line");
- it produced a real file (a plan), so there was something concrete to check.

Its weak part: the user had to ask twice what its definition of done was. It should say this at the start, without being asked.

The ideas below keep only the general parts. No goal-type templates, and nothing specific to discovery work.

## The rules

1. **Every item names its evidence.** Each "Done when" item says what a skeptical reader would look at to say "yes": a command, a file and section, or a fact they can observe. If you can't name the evidence, the item is too vague.
2. **Every item ends in a result, not an activity.** "X is decided / fixed / written", never "explored X" or "looked into X". An activity is never done; a result is.
3. **Give the output a fixed shape.** Structure what the goal produces (sections, fields, a list with a fixed form), so a script can check the **shape** and the reviewer judges the **content**. This turns most fluid goals into mixed goals. (The restaurace audit worked like this: a script checked coverage, the reviewer checked quality.)
4. **Draw the edge.** Name what is **not** in scope. Where possible, turn it into a guard in the check. The reviewer also checks that the edge held.
5. **Name what you can't prove.** If part of an item can't be proven (no access, no hardware, no answer from a person), it is allowed as an **open gap** with a one-line reason, never hidden. The reviewer judges whether the gap is real or a lazy skip.
6. **Say the definition of done at the start.** `/goal` shows the items and the edge in a few lines, then starts working **without waiting**. You correct it only if it's wrong.

## What would change

The hook logic does not change, and neither does the diagram. It's prompt and doc text, plus tests.

### 1. `/goal` prompt (`commands/goal.md`)

**Step 3** gets the general rules instead of today's single "be concrete" line:

> 3. Turn the goal into "Done when" items. Rules for every item:
>    - **It names its evidence:** what a skeptical reviewer, who did not see this chat, would look at to say yes (a command, a file and section, or a fact they can observe).
>    - **It is a result, not an activity:** "X is decided / fixed / written", never "explored X".
>    - **If the output is free-form** (text, a plan, a review), give it a fixed shape (sections, fields, a list with a fixed form), so the check can test the shape and the reviewer judges the content.
>
>    Also write **what is not in scope**. Where you can, put it into the check as a guard.
>    If an item stays vague, ask me short questions until it is concrete. …

**The `goal.md` template** gets one new section:

```
## Done when
- <result, with its evidence>
## Not in scope
- <what this goal must not do or change>
## Plan
```

**Step 7** (definition of done up front):

> 7. Show me the definition of done in a few lines: the "Done when" items, "Not in scope", and the check (or "none: a reviewer judges"). Do not wait for my answer. Start work at once on the first plan step.

**The proof format** gets one optional line:

```
## <the Done when item>
method: command | file-read | judgement
command: …
evidence: …
gap: <only if part of the item cannot be proven: what, and why it is outside your reach>
confidence: high | medium | low
```

> A `gap:` is allowed only for things you cannot reach (no access, no hardware, no answer from a person). Never use it for work you could still do.

### 2. The loop's follow-up (`hooks/eca-goal-loop.sh`, text only)

The "claim" hint gets half a sentence: *"…and a `gap:` line if part of an item cannot be proven."*

### 3. The reviewer prompt (text in the same hook)

Two new bullets:

> - Check that nothing under "Not in scope" was done or changed.
> - For each `gap:` line: is it really outside the agent's reach? A gap the agent could have closed itself makes the item `not-ok`. A real gap is `ok`, but list it under `Open gaps` in your answer.

### 4. Docs

- `docs/writing-goals.md`: a new section, **"Writing good Done when items"**, with the rules and a short bad/good example for each. It also covers `Not in scope` in the `goal.md` template and `gap:` in the proof format.
- `docs/how-it-works.md`: step 1 says that `/goal` shows the definition of done, and step 5 mentions the scope check and the gap check.

### 5. Tests

- A proof with a `gap:` line is accepted.
- The verification prompt contains the scope check and the gap check.
- `goal.md` with a `## Not in scope` section still counts the "Done when" items correctly.

## Notes for building it

- The hook already ignores unknown proof lines, so `gap:` needs no parser change. Check this with the new test.
- `goal_items` reads "Done when" up to the next `## ` heading, so a `## Not in scope` section after it is safe. The judge's `sed` range also stops at the next heading.
