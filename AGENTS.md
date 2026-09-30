# AGENTS.md

Notes for agents that work on eca-goal.

## Keep the README short

`README.md` explains what eca-goal is, why an ECA user wants it, the loop diagram, a quick start and the commands. Details go into `docs/`:

| File | Content |
|---|---|
| `docs/how-it-works.md` | every step, hard/mixed/fluid goals, pause reasons, safety rails, security, limits |
| `docs/writing-goals.md` | the state files, `goal.md`, the proof, writing a good check |
| `docs/install.md` | requirements, what the installer changes, options, uninstall |
| `docs/configuration.md` | `goal.md` keys, the optional LLM judge, environment variables |
| `docs/development.md` | tests, files, the diagram |

When you change behavior, update the matching doc in the same change.

`ideas/` holds plans that are **not built yet**. They are not user docs. When you build one, move what it describes into the right doc, and delete the idea file.

## Keep the loop diagram in sync

`README.md` has a Mermaid diagram of the goal loop, at the top of "How it works". When you change how the loop works (the lifecycle, the states, the conditions, what the hook checks, what the agent or the reviewer must do), update the diagram in the same change.

1. Edit the ` ```mermaid ` block in `README.md`.
2. Render it and look at the result, in both GitHub themes:

   ```bash
   # extract the diagram from the README
   awk '/^```mermaid$/{f=1;next} /^```$/{f=0} f' README.md >/tmp/loop.mmd
   # a puppeteer config that uses the system Chrome
   echo '{"executablePath": "/usr/bin/google-chrome", "args": ["--no-sandbox"]}' >/tmp/pp.json
   npx -y @mermaid-js/mermaid-cli@11 -p /tmp/pp.json -t dark    -b '#0d1117' -i /tmp/loop.mmd -o /tmp/loop-dark.png  -s 1.5
   npx -y @mermaid-js/mermaid-cli@11 -p /tmp/pp.json -t default -b '#ffffff' -i /tmp/loop.mmd -o /tmp/loop-light.png -s 1.5
   ```

   Change `executablePath` if Chrome is somewhere else.
3. Remove clutter until the picture is easy to read:
   - **No crossing lines.** Do not draw arrows back to the top. End each branch in its own `([↻ next turn])` node instead.
   - **Mark who does each step:** 👤 you (class `human`), 🤖 LLM (class `llm`), ⚙️ hook script (class `script`). Keep the `classDef` colors clearly different from each other.
   - **Show the main path only.** Rare cases (for example `check-broken`, ownership, re-injecting the goal after compaction) go into the text under the diagram, not into the diagram.
   - Keep labels short. Use `<br/>` for a second line.
4. Update the line under the diagram (the legend and the list of pauses) if it changed too.

## Tests

Run them after every change to the hooks, the commands or the installer:

```bash
test/run-tests.sh                   # installer + hooks, in temp dirs
test/e2e.py /path/to/eca            # end-to-end against a real `eca server`
```
