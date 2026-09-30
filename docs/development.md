# Development

## Tests

```bash
test/run-tests.sh              # installer + hooks, in temp dirs (about 135 checks)
test/run-tests.sh --no-schema  # skip the checks that need a schema validator
test/e2e.py /path/to/eca       # end-to-end against a real `eca server`
```

`test/e2e.py` starts a fake OpenAI-compatible LLM, installs eca-goal into a temporary config dir, and drives a real `eca server` over its JSON-RPC protocol. It checks that the commands load, that an invented `chat_id` does not start the loop, that typing `/goal-resume` claims the goal and injects it, that the loop runs to `done` through a claim and a verification (including a verification that forgets `verified: yes`, which rejects the claim), and that stopping a turn pauses the goal. It does not touch your real config.

## Files

```
install.sh                  installer / uninstaller
hooks/eca-goal-claim.sh     preRequest hook: /goal, /goal-resume, /goal-pause typed by you
hooks/eca-goal-loop.sh      postRequest hook: check, claim, proof, judge, verification, follow-up
hooks/eca-goal-context.sh   chatStart / postCompact hook: re-inject the goal
hooks/eca-goal-lib.sh       shared helpers (goal.md header, loop.json)
commands/goal*.md           /goal, /goal-status, /goal-pause, /goal-resume
config/eca-goal.hooks.json  the hooks fragment that goes into config.json
test/                       tests
LICENSE                     MIT
```

## The loop diagram

When you change how the loop works, update the diagram in the README too. See [AGENTS.md](../AGENTS.md) for how to render it and keep it readable.
