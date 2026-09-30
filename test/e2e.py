#!/usr/bin/env python3
"""eca-goal end-to-end test against a real `eca server`.

Starts a fake OpenAI-compatible LLM, installs eca-goal into a throwaway
XDG config dir, and drives ECA over its stdio JSON-RPC protocol:

  1. the custom commands (/goal, /goal-pause, ...) are loaded; an invented
     chat_id in goal.md does not start the loop, typing /goal-resume does
  2. /goal-resume injects the active goal into the prompt
  3. the postRequest hook loops: failing check -> followUp turns -> the fake
     LLM "fixes" the repo -> check passes -> nudge to claim -> the fake LLM
     writes proof.md and claims -> verification turn -> status done
     (the first verification "forgets" verified: yes: the claim is rejected
     and its review kept as review-1.md, the fake LLM claims again, and the
     second verification, review round 2, confirms)
  4. stopping a turn (chat/promptStop) pauses the goal
  5. status: auditing + verified: yes written by the agent itself is not
     accepted; the loop treats it as a claim and runs a real verification

Nothing outside a temp dir is touched. Usage: test/e2e.py /path/to/eca
"""
import json, os, pathlib, queue, re, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = pathlib.Path(__file__).resolve().parent.parent
ECA = sys.argv[1] if len(sys.argv) > 1 else shutil.which("eca")
if not ECA:
    sys.exit("usage: test/e2e.py /path/to/eca")

tmp = pathlib.Path(tempfile.mkdtemp(prefix="eca-goal-e2e-"))
ws = tmp / "ws"
state = ws / ".eca" / "eca-goal" / "goal.md"
proof = state.parent / "proof.md"
review = state.parent / "review.md"
llm_log = []  # every request body the fake LLM received
verifications = [0]  # verification turns seen by the fake LLM
PROOF = "## marker exists\nmethod: command\ncommand: test -f marker\nevidence: the file is there\nconfidence: high\n"


def set_header(key, value):
    head, sep, body = state.read_text().partition("\n---\n")
    head = re.sub(rf"^{key}:.*$", f"{key}: {value}", head, count=1, flags=re.M)
    state.write_text(head + sep + body)


# ---------------------------------------------------------------- fake LLM
def last_user_text(body):
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user":
            c = m.get("content")
            return c if isinstance(c, str) else " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


class FakeLLM(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "m", "object": "model"}]}).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        llm_log.append(body)
        text = last_user_text(body)
        if "SELFAUDIT" in text:  # the agent marks its own audit
            proof.write_text(PROOF)
            set_header("status", "auditing"); set_header("verified", "yes")
            reply = "Everything verified, goal complete."
        elif "fresh reviewer" in text:  # verification turn
            verifications[0] += 1
            review.write_text("verdict: pass\n- marker exists: ok\n")
            if verifications[0] > 1:  # the first one "forgets" verified: yes
                set_header("verified", "yes")
            reply = "Reviewer says pass."
        elif "you have not claimed the goal yet" in text or "did not confirm the goal" in text:
            proof.write_text(PROOF)
            set_header("status", "claimed")
            reply = "Claimed the goal."
        elif "Goal not met yet (iteration 2/" in text:
            (ws / "marker").touch()  # the "work" that makes the check pass
            reply = "Created the marker."
        elif "SLOW" in text:
            time.sleep(8)
            reply = "slow answer"
        else:
            reply = "Working on it."
        if body.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            def ev(d):
                self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n"); self.wfile.flush()
            base = {"id": "x", "object": "chat.completion.chunk", "model": "m"}
            ev({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply}, "finish_reason": None}]})
            ev({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        else:
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps({"id": "x", "object": "chat.completion", "model": "m",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode())

    def log_message(self, *a):
        pass


llm = ThreadingHTTPServer(("127.0.0.1", 0), FakeLLM)
threading.Thread(target=llm.serve_forever, daemon=True).start()

# ---------------------------------------------------------------- config + install
xdg = tmp / "xdg"; (xdg / "eca").mkdir(parents=True)
(xdg / "eca" / "config.json").write_text(json.dumps({
    "providers": {"fake": {"api": "openai-chat", "url": f"http://127.0.0.1:{llm.server_port}/v1",
                           "key": "none", "fetchModels": False, "models": {"m": {}}}},
    "defaultModel": "fake/m",
}, indent=2))
subprocess.run([str(REPO / "install.sh"), "--no-schema", "--config-dir", str(xdg / "eca")],
               check=True, stdout=subprocess.DEVNULL)

GOAL = """status: active
iteration: 0
max_iterations: 8
judge: off
verified: no
check: test -f marker
---
## Objective
E2E test goal.
## Done when
- marker exists
## Progress
"""
ws.mkdir(); state.parent.mkdir(parents=True); state.write_text(GOAL)

env = {**os.environ, "HOME": str(tmp / "home"), "XDG_CONFIG_HOME": str(xdg),
       "XDG_CACHE_HOME": str(tmp / "cache"), "XDG_DATA_HOME": str(tmp / "data")}
(tmp / "home").mkdir()

# ---------------------------------------------------------------- JSON-RPC client
proc = subprocess.Popen([ECA, "server"], cwd=ws, env=env, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=open(tmp / "eca.stderr", "wb"))
inbox = queue.Queue()
responses = {}
notes = []


def reader():
    f = proc.stdout
    while True:
        headers = {}
        while True:
            line = f.readline()
            if not line:
                return
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(":", 1); headers[k.lower()] = v.strip()
        msg = json.loads(f.read(int(headers["content-length"])))
        inbox.put(msg)


threading.Thread(target=reader, daemon=True).start()
next_id = [0]


def send(msg):
    data = json.dumps(msg).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data); proc.stdin.flush()


def pump(timeout=0.2):
    try:
        while True:
            m = inbox.get(timeout=timeout)
            if "id" in m and "method" in m:  # server -> client request: answer with null
                send({"jsonrpc": "2.0", "id": m["id"], "result": None})
            elif "id" in m:
                responses[m["id"]] = m
            else:
                notes.append(m)
            timeout = 0.01
    except queue.Empty:
        pass


def request(method, params, timeout=60):
    next_id[0] += 1; i = next_id[0]
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    end = time.time() + timeout
    while time.time() < end:
        pump()
        if i in responses:
            return responses.pop(i)
    raise TimeoutError(method)


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def header(key):
    for line in state.read_text().splitlines():
        if line == "---":
            break
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return ""


loop_file = state.parent / "loop.json"


def loop_owner():
    return json.loads(loop_file.read_text()).get("owner") if loop_file.exists() else None


def wait_for(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        pump()
        if pred():
            return True
    return False


def hook_messages():
    out = []
    for n in notes:
        if n.get("method") == "chat/contentReceived":
            c = n["params"].get("content", {})
            t = c.get("text") or ""
            if "eca-goal" in t or c.get("type") == "hookActionFinished":
                out.append(t or json.dumps(c)[:200])
    return out


results = []
def check(name, ok):
    results.append(ok); print(("  ok   " if ok else "  FAIL ") + name)


try:
    print(f"== e2e ({ECA}, {subprocess.run([ECA, '--version'], capture_output=True, text=True).stdout.strip()})")
    request("initialize", {"processId": os.getpid(), "clientInfo": {"name": "eca-goal-e2e"},
                           "capabilities": {"codeAssistant": {"chat": True}},
                           "workspaceFolders": [{"uri": ws.as_uri(), "name": "ws"}]})
    notify("initialized", {})

    cmds = request("chat/queryCommands", {"query": ""})["result"]["commands"]
    names = {c["name"] for c in cmds}
    check("commands /goal /goal-pause /goal-resume /goal-status loaded",
          {"goal", "goal-pause", "goal-resume", "goal-status"} <= names)

    # an invented chat_id in goal.md, and no /goal typed: the loop must stay off
    state.write_text(GOAL.replace("iteration: 0", "chat_id: c0\niteration: 0", 1))
    request("chat/prompt", {"chatId": "c0", "message": "just chatting", "model": "fake/m", "trust": True})
    wait_for(lambda: any("no chat owns it" in m for m in hook_messages()), 30)
    check("invented chat_id, no /goal typed -> loop off, user is told",
          any("no chat owns it" in m for m in hook_messages()) and header("iteration") == "0"
          and not any("Goal not met yet" in last_user_text(b) for b in llm_log))

    state.write_text(GOAL)
    request("chat/prompt", {"chatId": "c1", "message": "/goal-resume start working", "model": "fake/m", "trust": True})
    done = wait_for(lambda: header("status") == "done", 120)
    check("loop runs until status: done", done)
    check("typed /goal-resume claimed the goal for c1 (preRequest saw the raw command)", loop_owner() == "c1")
    check("done confirmed by the loop", json.loads(loop_file.read_text()).get("done_confirmed") is True)
    check("took 6 iterations (2 failed, nudge, claim, rejected verification, claim again)", header("iteration") == "6")
    prompts = [last_user_text(b) for b in llm_log]
    check("unconfirmed verification did not end the goal (rejection reached the LLM)",
          any("ended without `verified: yes`" in p for p in prompts))
    check("followUp turns 1 and 2 reached the LLM",
          all(any(f"Goal not met yet (iteration {i}/8)" in p for p in prompts) for i in (1, 2)))
    check("passing check without a claim -> nudge reached the LLM",
          any("you have not claimed the goal yet" in p for p in prompts))
    check("two verification turns reached the LLM", verifications[0] == 2)
    check("the rejected review was kept as review-1.md", (state.parent / "review-1.md").exists())
    check("the 2nd verification was review round 2, with the earlier review",
          any("review round 2" in p and "review-1.md" in p for p in prompts))
    check("typed /goal-resume injected the goal into the prompt",
          any("this chat now owns the goal" in json.dumps(b) for b in llm_log))

    # stop a turn -> goal paused
    (ws / "marker").unlink(); proof.unlink(missing_ok=True); review.unlink(missing_ok=True)
    state.write_text(GOAL)
    request("chat/prompt", {"chatId": "c2", "message": "/goal-resume SLOW please", "model": "fake/m", "trust": True})
    time.sleep(2); pump()
    notify("chat/promptStop", {"chatId": "c2"})
    paused = wait_for(lambda: header("status") == "paused", 30)
    check("stopping a turn pauses the goal", paused)
    check("  stopped turn did not count as an iteration", header("iteration") == "0")
    check("  paused_reason: user-stop", header("paused_reason") == "user-stop")
    time.sleep(8); pump()
    check("  no follow-up turn after the stop",
          not any("Goal not met yet" in last_user_text(b) for b in llm_log[-3:]))

    # the agent writes status: auditing + verified: yes itself -> the loop must not accept it
    (ws / "marker").touch()
    state.write_text(GOAL)
    request("chat/prompt", {"chatId": "c3", "message": "/goal-resume SELFAUDIT", "model": "fake/m", "trust": True})
    done3 = wait_for(lambda: header("status") == "done", 60)
    prompts3 = [last_user_text(b) for b in llm_log]
    check("self-set auditing + verified: yes is not accepted: the loop ran its checks and a real verification",
          done3 and any("was set by you, not by the loop" in p for p in prompts3)
          and int(json.loads(loop_file.read_text()).get("iteration", 0)) >= 1)
    check("  and then confirmed done", json.loads(loop_file.read_text()).get("done_confirmed") is True)
finally:
    try:
        request("shutdown", {}, timeout=10); notify("exit", {})
    except Exception:
        pass
    proc.kill()
    llm.shutdown()
    if not all(results):
        print(f"\nstate file:\n{state.read_text() if state.exists() else '(none)'}")
        print(f"eca stderr (tail):\n{(tmp / 'eca.stderr').read_text()[-3000:]}")
        print(f"hook messages: {hook_messages()[-10:]}")
        print(f"kept temp dir: {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)

print(f"\npassed: {sum(results)}, failed: {len(results) - sum(results)}")
sys.exit(0 if results and all(results) else 1)
