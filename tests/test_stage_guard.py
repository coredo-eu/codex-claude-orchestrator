#!/usr/bin/env python3
"""Hermetic tests for the content-free parent-stage checkpoint hook."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD = (
    ROOT
    / "plugins/codex-claude-orchestrator/skills/claude-pty-agents/scripts/worker-stage-guard.zsh"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    path.chmod(0o600)


def assistant_record(request_id: str, cache_read: int, sentinel: str) -> dict[str, object]:
    return {
        "type": "assistant",
        "isSidechain": False,
        "requestId": request_id,
        "uuid": str(uuid.uuid4()),
        "message": {
            "id": f"message-{request_id}",
            "usage": {"cache_read_input_tokens": cache_read},
            "content": [{"type": "text", "text": sentinel}],
        },
    }


def append_record(path: Path, value: object) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, separators=(",", ":")) + "\n")


def run_guard(
    zsh: str,
    registration: Path,
    transcript: Path,
    session_id: str,
    home: Path,
    *,
    tool_name: str = "Read",
    agent_id: str | None = None,
    agent_role: str = "explorer",
) -> subprocess.CompletedProcess[str]:
    payload: dict[str, object] = {
        "hook_event_name": "PreToolUse",
        "session_id": session_id,
        "transcript_path": str(transcript),
        "tool_name": tool_name,
        "tool_input": {"subagent_type": agent_role} if tool_name == "Agent" else {"file_path": "/fixture"},
    }
    if agent_id is not None:
        payload["agent_id"] = agent_id
        payload["agent_type"] = "explorer"
    env = os.environ.copy()
    env["HOME"] = str(home)
    return subprocess.run(
        [zsh, str(GUARD), str(registration)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def main() -> int:
    zsh = subprocess.run(
        ["sh", "-c", "command -v zsh"], text=True, capture_output=True, check=True
    ).stdout.strip()
    require(bool(zsh), "zsh unavailable")

    with tempfile.TemporaryDirectory(prefix="cco-stage-guard-") as temporary:
        base = Path(temporary)
        home = base / "home"
        project_logs = home / ".claude/projects/fixture"
        project_logs.mkdir(parents=True)
        session_id = str(uuid.uuid4())
        transcript = project_logs / f"{session_id}.jsonl"
        transcript.touch(mode=0o600)

        registration = home / ".codex/claude-pty-sessions" / session_id
        health = registration / "health"
        health.mkdir(parents=True, mode=0o700)
        (registration / "session_uuid").write_text(session_id + "\n", encoding="utf-8")
        (health / "health_schema_version").write_text("1\n", encoding="utf-8")
        write_json(
            health / "policy.json",
            {
                "schema_version": 1,
                "warn_requests": 2,
                "max_requests": 3,
                "warn_parent_tool_calls": 10,
                "max_parent_tool_calls": 20,
                "warn_cache_read_input_tokens": 50,
                "max_cache_read_input_tokens": 500,
                "warn_elapsed_seconds": 600,
                "max_elapsed_seconds": 1200,
            },
        )
        write_json(
            health / "assignment.json",
            {"schema_version": 1, "assigned_at_epoch": int(time.time()), "task_id": "fixture-stage"},
        )
        for name in (
            "parent_tool_calls",
            "agent_calls",
            "transcript_cursor_bytes",
            "max_cache_read_input_tokens",
            "warning_emitted",
        ):
            (health / name).write_text("0\n", encoding="utf-8")
            (health / name).chmod(0o600)
        write_json(
            health / "agent_calls_by_role.json",
            {
                "schema_version": 1,
                "calls": {
                    "explorer": 0,
                    "log-analyzer": 0,
                    "test-triager": 0,
                    "scout": 0,
                    "implementer": 0,
                    "debugger": 0,
                    "reviewer": 0,
                    "security-reviewer": 0,
                    "long-horizon": 0,
                },
            },
        )
        (health / "request_keys.log").touch(mode=0o600)

        sentinel = "PROMPT_CONTENT_MUST_NOT_PERSIST"
        first = assistant_record("request-one", 10, sentinel)
        append_record(transcript, first)
        append_record(transcript, first)
        healthy = run_guard(zsh, registration, transcript, session_id, home)
        require(healthy.returncode == 0 and healthy.stdout == "", f"healthy call was not transparent: {healthy}")
        require((health / "request_keys.log").read_text(encoding="utf-8") == "request-one\n", "duplicate request counted")

        role_counter = health / "agent_calls_by_role.json"
        missing_role_counter = health / "agent_calls_by_role.missing"
        role_counter.rename(missing_role_counter)
        missing_counter = run_guard(zsh, registration, transcript, session_id, home)
        require(
            json.loads(missing_counter.stdout)["hookSpecificOutput"].get("permissionDecision") == "deny",
            "missing per-role counter failed open",
        )
        missing_role_counter.rename(role_counter)

        subagent = run_guard(
            zsh, registration, transcript, session_id, home, agent_id="agent-fixture"
        )
        require(subagent.returncode == 0 and subagent.stdout == "", "subagent tool was not skipped")
        require((health / "parent_tool_calls").read_text().strip() == "1", "subagent tool changed parent count")

        append_record(transcript, assistant_record("request-two", 100, sentinel))
        warning = run_guard(zsh, registration, transcript, session_id, home, tool_name="Agent")
        warning_json = json.loads(warning.stdout)
        warning_output = warning_json["hookSpecificOutput"]
        require("additionalContext" in warning_output, "warning lacks additionalContext")
        require("permissionDecision" not in warning_output, "warning silently approved or denied the tool")
        require((health / "agent_calls").read_text().strip() == "1", "parent Agent call was not counted")
        require(
            json.loads((health / "agent_calls_by_role.json").read_text(encoding="utf-8"))["calls"]["explorer"] == 1,
            "parent Agent role was not counted",
        )

        repeated = run_guard(zsh, registration, transcript, session_id, home)
        require(repeated.stdout == "", "one-time warning repeated")

        append_record(transcript, assistant_record("request-three", 120, sentinel))
        checkpoint = run_guard(zsh, registration, transcript, session_id, home)
        checkpoint_json = json.loads(checkpoint.stdout)["hookSpecificOutput"]
        require(checkpoint_json.get("permissionDecision") == "deny", "checkpoint did not deny the next tool")
        require((health / "checkpoint.json").is_file(), "checkpoint marker missing")
        require(not (registration / "retirement.json").exists(), "checkpoint retired the worker")
        checkpoint_calls = (health / "parent_tool_calls").read_text(encoding="utf-8")
        repeated_checkpoint = run_guard(zsh, registration, transcript, session_id, home)
        require(
            json.loads(repeated_checkpoint.stdout)["hookSpecificOutput"].get("permissionDecision")
            == "deny",
            "durable checkpoint allowed a later tool",
        )
        require(
            (health / "parent_tool_calls").read_text(encoding="utf-8") == checkpoint_calls,
            "checkpointed stage kept accounting attempted tools",
        )

        persisted = "\n".join(
            path.read_text(encoding="utf-8")
            for path in registration.rglob("*")
            if path.is_file()
        )
        require(sentinel not in persisted, "transcript content leaked into registration state")
        observation = json.loads((health / "last_observation.json").read_text(encoding="utf-8"))
        require(
            observation["requests"] == 3
            and observation["max_cache_read_input_tokens"] == 120
            and observation["agent_calls_by_role"]["explorer"] == 1
            and observation["state"] == "checkpoint",
            f"content-free accounting drift: {observation}",
        )

        fallback_id = str(uuid.uuid4())
        fallback_registration = home / ".codex/claude-pty-sessions" / fallback_id
        fallback_health = fallback_registration / "health"
        fallback_health.mkdir(parents=True, mode=0o700)
        (fallback_registration / "session_uuid").write_text(fallback_id + "\n", encoding="utf-8")
        (fallback_health / "health_schema_version").write_text("1\n", encoding="utf-8")
        write_json(
            fallback_health / "policy.json",
            {
                "schema_version": 1,
                "warn_requests": 0,
                "max_requests": 0,
                "warn_parent_tool_calls": 0,
                "max_parent_tool_calls": 1,
                "warn_cache_read_input_tokens": 0,
                "max_cache_read_input_tokens": 0,
                "warn_elapsed_seconds": 0,
                "max_elapsed_seconds": 0,
            },
        )
        write_json(
            fallback_health / "assignment.json",
            {"schema_version": 1, "assigned_at_epoch": int(time.time()), "task_id": "fallback-stage"},
        )
        for name in (
            "parent_tool_calls",
            "agent_calls",
            "transcript_cursor_bytes",
            "max_cache_read_input_tokens",
            "warning_emitted",
        ):
            (fallback_health / name).write_text("0\n", encoding="utf-8")
            (fallback_health / name).chmod(0o600)
        write_json(
            fallback_health / "agent_calls_by_role.json",
            {
                "schema_version": 1,
                "calls": {
                    "explorer": 0,
                    "log-analyzer": 0,
                    "test-triager": 0,
                    "scout": 0,
                    "implementer": 0,
                    "debugger": 0,
                    "reviewer": 0,
                    "security-reviewer": 0,
                    "long-horizon": 0,
                },
            },
        )
        (fallback_health / "request_keys.log").touch(mode=0o600)
        unavailable = run_guard(
            zsh,
            fallback_registration,
            project_logs / f"{fallback_id}.jsonl",
            fallback_id,
            home,
        )
        require(
            json.loads(unavailable.stdout)["hookSpecificOutput"].get("permissionDecision") == "deny"
            and json.loads((fallback_health / "last_observation.json").read_text())["transcript_state"]
            == "unavailable",
            "parent-tool fallback did not checkpoint without transcript telemetry",
        )

    print("stage guard: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"stage guard: FAIL: {exc}", file=os.sys.stderr)
        raise SystemExit(1)
