#!/usr/bin/env python3
"""Hermetic content-free parent-stage checkpoint coverage."""
import json, os, subprocess, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "plugins/codex-claude-orchestrator/skills/claude-pty-agents/scripts/worker-stage-guard.zsh"
def require(value, message):
    if not value: raise AssertionError(message)
def main():
  zsh = subprocess.check_output(["sh", "-c", "command -v zsh"], text=True).strip()
  with tempfile.TemporaryDirectory() as temp:
    base=Path(temp); home=base/"home"; sid=str(uuid.uuid4()); transcript=home/".claude/projects/x"/(sid+".jsonl"); transcript.parent.mkdir(parents=True); transcript.touch()
    registration=home/".codex/claude-pty-sessions"/sid; health=registration/"health"; health.mkdir(parents=True); (registration/"session_uuid").write_text(sid+"\n")
    def write(path, data): path.write_text(json.dumps(data)+"\n")
    (health/"health_schema_version").write_text("1\n")
    write(health/"policy.json", {"schema_version":1,"warn_requests":2,"max_requests":3,"warn_parent_tool_calls":10,"max_parent_tool_calls":20,"warn_cache_read_input_tokens":50,"max_cache_read_input_tokens":500,"warn_elapsed_seconds":600,"max_elapsed_seconds":1200})
    write(health/"assignment.json", {"schema_version":1,"assigned_at_epoch":int(time.time()),"task_id":"stage"})
    for name in ("parent_tool_calls","agent_calls","transcript_cursor_bytes","max_cache_read_input_tokens","warning_emitted"): (health/name).write_text("0\n")
    write(health/"agent_calls_by_role.json", {"schema_version":1,"calls":{"explorer":0,"codeindexer-explorer":0,"scout":0,"log-analyzer":0,"test-triager":0,"implementer":0,"debugger":0,"reviewer":0,"security-reviewer":0,"long-horizon":0}})
    (health/"request_keys.log").touch()
    sentinel="PROMPT_CONTENT_MUST_NOT_PERSIST"
    def row(key, cache): return {"type":"assistant","isSidechain":False,"requestId":key,"message":{"usage":{"cache_read_input_tokens":cache},"content":[{"text":sentinel}]}}
    def call(agent=None, role=None):
      payload={"hook_event_name":"PreToolUse","session_id":sid,"transcript_path":str(transcript),"tool_name":"Agent","tool_input":{}}
      if agent: payload["agent_id"]=agent
      if role: payload["tool_input"]["subagent_type"]=role
      env=os.environ.copy(); env["HOME"]=str(home)
      return subprocess.run([zsh,str(GUARD),str(registration)],input=json.dumps(payload),text=True,capture_output=True,env=env)
    with transcript.open("a") as out: out.write(json.dumps(row("one",10))+"\n"+json.dumps(row("one",10))+"\n")
    require(call(role="scout").stdout=="", "duplicate request was not transparent")
    role_calls=json.loads((health/"agent_calls_by_role.json").read_text())["calls"]
    require(role_calls["scout"] == 1 and sum(role_calls.values()) == 1, "per-role agent call counter drift")
    require(call("subagent").stdout=="" and (health/"parent_tool_calls").read_text().strip()=="1", "agent_id bypass drift")
    with transcript.open("a") as out: out.write(json.dumps(row("two",100))+"\n")
    require("additionalContext" in call().stdout, "warning missing")
    with transcript.open("a") as out: out.write(json.dumps(row("three",120))+"\n")
    require("permissionDecision" in call().stdout and (health/"checkpoint.json").is_file(), "durable checkpoint missing")
    persisted="".join(p.read_text() for p in registration.rglob("*") if p.is_file())
    require(sentinel not in persisted, "transcript content persisted")
  print("stage guard: PASS")
if __name__ == "__main__":
  try: main()
  except AssertionError as exc: raise SystemExit(f"stage guard: FAIL: {exc}")
