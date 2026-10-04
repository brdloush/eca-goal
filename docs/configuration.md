# Configuration

## Keys in goal.md

| Key | Default | Meaning |
|---|---|---|
| `max_iterations` | `50` | Turns before the goal pauses (`budget`). One iteration is one turn. |
| `stall_limit` | `3` | Identical failed checks (or identical proof-command failures at claims) in a row before the goal pauses (`stall`). |
| `claim_limit` | `3` | Rejected claims (failed verifications, judge "no") before the goal pauses (`claims-rejected`). |
| `judge` | `off` | `local` turns on the optional LLM judge (below). |

## Optional LLM judge

> [!WARNING]
> **The judge cannot see your files, and it cannot call tools.** It is one plain chat request: no tools, no file system access. It also does not see the agent's chat, tool calls or tool output. It knows only the text the hook sends: the "Done when" items, `proof.md`, the check output and the agent's last message. So it judges what the agent **says** it did, not what is in the repo. If the proof is wrong or incomplete, the judge cannot notice. The fresh reviewer is the real check: it reads the repo itself.

The fresh reviewer already judges items that no command can prove. Use the judge only if you want an extra "no" from a **second, different model**, for example a local one. Set `judge: local`. On a claim, after the check and the proof commands passed, the hook asks an OpenAI-compatible endpoint (for example llama.cpp or Ollama) if every item is met, based only on the text above. If the judge says no, or cannot be reached, or times out, the claim is **rejected**. So a slow or broken judge counts toward `claim_limit` and can pause the goal.

Tips:
- **Ollama** needs `ECA_GOAL_JUDGE_MODEL`: a model id from `GET /v1/models`, for example `qwen3-coder:30b`. Without a model, the request fails and the claim is rejected.
- **Slow models** (for example on CPU): a 35B model took about 2 minutes for a tiny proof. Raise `ECA_GOAL_JUDGE_TIMEOUT` so a big proof does not time out.

The hooks read these variables from **ECA's environment**:

| Variable | Default | Meaning |
|----------|---------|---------|
| `ECA_GOAL_JUDGE_URL` | (none) | Base URL, e.g. `http://localhost:8080`. `/v1/chat/completions` is added. Required for `judge: local`. |
| `ECA_GOAL_JUDGE_MODEL` | (none) | `model` field for the request, if your server needs it. |
| `ECA_GOAL_JUDGE_API_KEY` | (none) | Sent as `Authorization: Bearer ...`. |
| `ECA_GOAL_JUDGE_TIMEOUT` | `180` | Seconds. |
| `ECA_GOAL_CHECK_TIMEOUT` | `900` | Seconds for the check command. |
| `ECA_GOAL_SLOW_CHECK` | `120` | Seconds. A check that takes longer gets a hint to the agent, once per goal: make it faster without sacrificing correctness, or write why not under Notes. Set a large number to turn the hint off. |
| `ECA_GOAL_OUTPUT_LINES` | `60` | Lines of check output sent back to the agent. |
