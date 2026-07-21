#!/usr/bin/env python3
"""PTY lifecycle tests using a fake Claude executable and an isolated HOME."""

from __future__ import annotations

import errno
import hashlib
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "plugins/codex-claude-orchestrator/skills/claude-pty-agents/scripts"
LAUNCHER = SCRIPTS / "launch-worker.zsh"
ASSIGN = SCRIPTS / "assign-worker.zsh"
ROTATE = SCRIPTS / "rotate-worker.zsh"
COMPACTION_COUNTER = SCRIPTS / "worker-compaction-counter.zsh"
RETIRE = SCRIPTS / "retire-native-fallback.zsh"
TOGGLE = SCRIPTS / "toggle-agents.zsh"
SETUP = SCRIPTS / "setup-native-agents.zsh"
NATIVE_RUNNER = SCRIPTS / "run-native-agent.zsh"
ROUTER = SCRIPTS / "worker-agent-router.zsh"
CODEINDEXER_GUARD = SCRIPTS / "worker-codeindexer-guard.zsh"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def start_pty(command: list[str], *, cwd: Path, env: dict[str, str]) -> tuple[subprocess.Popen[bytes], int]:
    master, slave = pty.openpty()
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    return process, master


def read_pty(process: subprocess.Popen[bytes], master: int, *, needle: str | None = None, timeout: float = 10.0) -> str:
    deadline = time.monotonic() + timeout
    chunks: list[bytes] = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
            text = b"".join(chunks).decode("utf-8", errors="replace")
            if needle and needle in text:
                return text
        if process.poll() is not None and not ready:
            break
    return b"".join(chunks).decode("utf-8", errors="replace")


def wait_for(path: Path, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}")


def process_is_live(pid: int) -> bool:
    observed = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="], text=True, capture_output=True, check=False
    )
    state = observed.stdout.strip()
    return observed.returncode == 0 and bool(state) and not state.startswith("Z")


def wait_for_process_exit(pid: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_is_live(pid):
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for process {pid} to exit")


def option_value(argv: list[str], option: str) -> str:
    index = argv.index(option)
    return argv[index + 1]


def run_assign(
    zsh: str,
    repo: Path,
    worker_uuid: str,
    task_id: str,
    env: dict[str, str],
    *,
    continue_context: bool = False,
) -> subprocess.CompletedProcess[str]:
    command = [zsh, str(ASSIGN), str(repo), worker_uuid, task_id]
    if continue_context:
        command.append("--continue-current-context")
    return subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True, check=False)


def marker_payload(completed: subprocess.CompletedProcess[str], marker: str) -> dict:
    line = next((line for line in completed.stdout.splitlines() if line.startswith(marker + " ")), "")
    require(bool(line), f"{marker} missing: {completed.stdout} {completed.stderr}")
    return json.loads(line.split(" ", 1)[1])


def run_rotate(
    zsh: str, repo: Path, worker_uuid: str, task_id: str, env: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            zsh,
            str(ROTATE),
            str(repo),
            worker_uuid,
            task_id,
            "--handoff",
            "ready_for_verification",
            "--custody-returned",
        ],
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def write_fake_claude(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

record = Path(os.environ["FAKE_CLAUDE_RECORD"])
payload = {
    "argv": sys.argv[1:],
    "cwd": os.getcwd(),
    "subagent_model": os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL"),
    "disable_auto_memory": os.environ.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY"),
    "disable_explore_plan": os.environ.get("CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS"),
    "disable_git_instructions": os.environ.get("CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS"),
}
tmp = record.with_suffix(".tmp")
tmp.write_text(json.dumps(payload), encoding="utf-8")
tmp.replace(record)

child_record = os.environ.get("FAKE_CLAUDE_CHILD_PID")
if child_record:
    child = subprocess.Popen([
        sys.executable,
        "-c",
        "import time\\nwhile True: time.sleep(0.1)",
    ])
    Path(child_record).write_text(str(child.pid), encoding="utf-8")

def stop(_signum, _frame):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(0.1)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_fake_codex(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

record = Path(os.environ["FAKE_CODEX_RECORD"])
payload = {
    "argv": sys.argv[1:],
    "stdin": sys.stdin.read(),
}
tmp = record.with_suffix(".tmp")
tmp.write_text(json.dumps(payload), encoding="utf-8")
tmp.replace(record)
print("isolated native result")
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def main() -> int:
    zsh = shutil.which("zsh")
    jq = shutil.which("jq")
    git = shutil.which("git")
    require(bool(zsh and jq and git), "zsh, jq, and git are required for runtime tests")

    route_models = {
        "explorer": "haiku",
        "log-analyzer": "haiku",
        "test-triager": "haiku",
        "implementer": "sonnet",
        "debugger": "sonnet",
        "reviewer": "opus",
        "security-reviewer": "opus",
        "long-horizon": "fable",
    }
    for role, model in route_models.items():
        for supplied_model in (None, model):
            tool_input = {"subagent_type": role, "prompt": "bounded outcome", "description": "test"}
            if supplied_model is not None:
                tool_input["model"] = supplied_model
            routed = subprocess.run(
                [zsh, str(ROUTER)],
                input=json.dumps(
                    {"hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_input": tool_input}
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            require(routed.returncode == 0 and not routed.stdout, f"valid route was denied: {role}")

    denied_route_inputs = (
        json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Agent",
                "tool_input": {"subagent_type": "explorer", "model": "opus"},
            }
        ),
        json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Agent",
                "tool_input": {"subagent_type": "general-purpose"},
            }
        ),
        "not-json",
    )
    for payload in denied_route_inputs:
        routed = subprocess.run(
            [zsh, str(ROUTER)], input=payload, text=True, capture_output=True, check=False
        )
        require(routed.returncode == 0, "router failed open through a nonzero hook error")
        decision = json.loads(routed.stdout)["hookSpecificOutput"]
        require(decision["permissionDecision"] == "deny", "invalid route was not denied")

    codeindexer_cases = (
        ("mcp__codeindexer__search_code", {"project": "repo", "query": "symbol"}, True),
        ("mcp__codeindexer__projects", {"action": "list"}, True),
        ("mcp__codeindexer__projects", {"action": "delete", "project": "repo"}, False),
        ("mcp__codeindexer__projects", {"action": "diff", "audit": True}, False),
        ("mcp__codeindexer__memory_cards", {"action": "update", "id": "card"}, False),
        ("mcp__codeindexer__unknown", "malformed", False),
    )
    for tool_name, tool_input, allowed in codeindexer_cases:
        guarded = subprocess.run(
            [zsh, str(CODEINDEXER_GUARD)],
            input=json.dumps(
                {"hook_event_name": "PreToolUse", "tool_name": tool_name, "tool_input": tool_input}
            ),
            text=True,
            capture_output=True,
            check=False,
        )
        require(guarded.returncode == 0, f"CodeIndexer guard hook failed: {tool_name}")
        if allowed:
            require(not guarded.stdout, f"read-only CodeIndexer call was denied: {tool_name}")
        else:
            decision = json.loads(guarded.stdout)["hookSpecificOutput"]
            require(decision["permissionDecision"] == "deny", f"CodeIndexer mutation was allowed: {tool_name}")

    with tempfile.TemporaryDirectory(prefix="cco-test-") as temp:
        base = Path(temp).resolve()
        home = base / "home with space"
        repo = base / "repo with space"
        fake_bin = base / "fake bin"
        home.mkdir()
        repo.mkdir()
        fake_bin.mkdir()
        subprocess.run([git, "init", "-q", "-b", "main", str(repo)], check=True)

        fake_claude = fake_bin / "claude"
        write_fake_claude(fake_claude)
        record = base / "claude record.json"
        child_record = base / "claude child.pid"
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                "CODEX_THREAD_ID": "integration-thread",
                "CLAUDE_CODE_SUBAGENT_MODEL": "inherited-global-sentinel",
                "CODEX_CLAUDE_SUBAGENT_MODEL": "legacy-global-sentinel",
                "FAKE_CLAUDE_RECORD": str(record),
                "FAKE_CLAUDE_CHILD_PID": str(child_record),
            }
        )

        # These assertions measure what the launcher sets, so Claude Code
        # control variables from the surrounding session must not leak in.
        for ambient in (
            "CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
            "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS",
        ):
            env.pop(ambient, None)

        claude_state = home / ".claude.json"
        claude_state.write_text(
            json.dumps(
                {"mcpServers": {"codeindexer": {"type": "http", "url": "https://example.com/mcp"}}}
            ),
            encoding="utf-8",
        )
        invalid_mcp, invalid_mcp_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=env)
        invalid_mcp_output = read_pty(invalid_mcp, invalid_mcp_master, timeout=10)
        invalid_mcp.wait(timeout=5)
        os.close(invalid_mcp_master)
        require(
            invalid_mcp.returncode == 65 and "WORKER_MCP_CONFIG_INVALID" in invalid_mcp_output,
            "remote CodeIndexer config was accepted",
        )
        require(not (home / ".codex/claude-pty-sessions").exists(), "invalid MCP launch created a registration")
        claude_state.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "codeindexer": {"type": "http", "url": "http://127.0.0.1:8978/mcp"},
                        "unrelated": {"command": "other-mcp", "env": {"TOKEN": "MUST_NOT_COPY"}},
                    },
                    "unrelatedState": True,
                }
            ),
            encoding="utf-8",
        )

        worker, master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=env)
        output = read_pty(worker, master, needle="CODEX_PTY_WORKER_READY")
        require("CODEX_PTY_WORKER_READY" in output, f"worker did not become ready: {output}")
        ready_line = next((line for line in output.splitlines() if "CODEX_PTY_WORKER_READY " in line), "")
        require(bool(ready_line), "ready marker missing JSON")
        ready_payload = ready_line.split("CODEX_PTY_WORKER_READY ", 1)[1].strip()
        ready = json.loads(ready_payload)
        worker_uuid = ready["uuid"]
        lease = Path(ready["lease"])
        require(ready["root"] == str(repo), "ready marker did not preserve a root containing spaces")
        expected_agent_models = {
            "explorer": "haiku",
            "log-analyzer": "haiku",
            "test-triager": "haiku",
            "implementer": "sonnet",
            "debugger": "sonnet",
            "reviewer": "opus",
            "security-reviewer": "opus",
            "long-horizon": "fable",
        }
        require(
            ready["runtime_schema"] == "4"
            and ready["context_state"] == "observed"
            and ready["context_compactions"] == 0
            and ready["lineage_kind"] == "standalone",
            f"new worker lifecycle marker drift: {ready}",
        )
        require(ready["agent_models"] == expected_agent_models, "ready marker model roster drift")
        wait_for(record)
        wait_for(child_record)
        child_pid = int(child_record.read_text(encoding="utf-8"))

        observed = json.loads(record.read_text(encoding="utf-8"))
        argv = observed["argv"]
        require(observed["cwd"] == str(repo), "fake Claude cwd drift")
        require(observed["subagent_model"] is None, "inherited global Claude model override was not cleared")
        require(observed["disable_auto_memory"] == "1", "auto-memory was not disabled")
        require(observed["disable_explore_plan"] == "1", "built-in Explore/Plan agents were not disabled")
        require(observed["disable_git_instructions"] == "1", "automatic Git instructions were not disabled")
        require(option_value(argv, "--model") == "opus", "parent model is not Opus")
        agents = json.loads(option_value(argv, "--agents"))
        require(
            {name: definition["model"] for name, definition in agents.items()} == expected_agent_models,
            "Claude CLI role model map drift",
        )
        read_only_roles = (
            "explorer", "log-analyzer", "test-triager", "debugger", "reviewer", "security-reviewer"
        )
        require(
            all(agents[role]["tools"] == ["Read", "Grep", "Glob", "Bash"] for role in read_only_roles),
            "read-only Claude tool boundary drift",
        )
        require(
            all(agents[role].get("permissionMode") == "plan" for role in read_only_roles),
            "read-only Claude permission mode drift",
        )
        require(
            "Agent" not in {tool for definition in agents.values() for tool in definition["tools"]},
            "recursive Agent tool enabled",
        )
        require(option_value(argv, "--setting-sources") == "", "private settings sources were loaded")
        require("--strict-mcp-config" in argv, "strict MCP mode missing")
        mcp_path = Path(option_value(argv, "--mcp-config"))
        require("--dangerously-skip-permissions" not in argv, "permission bypass was enabled")
        denied_agents = set(argv[argv.index("--disallowedTools") + 1 :])
        require(
            {
                "Agent(Explore)",
                "Agent(Plan)",
                "Agent(general-purpose)",
                "Agent(statusline-setup)",
                "Agent(claude-code-guide)",
            }.issubset(denied_agents),
            "built-in Claude agents were not denied",
        )

        settings_path = Path(option_value(argv, "--settings"))
        prompt_path = Path(option_value(argv, "--append-system-prompt-file"))
        runtime_dir = settings_path.parent
        require(str(runtime_dir).startswith(str(home / ".codex/claude-pty-sessions")), "runtime escaped private state")
        require(prompt_path.parent == runtime_dir, "worker does not use one runtime snapshot")
        require(stat.S_IMODE(runtime_dir.stat().st_mode) == 0o700, "runtime directory is not 0700")
        agents_path = runtime_dir / "worker-agents.json"
        for path in (settings_path, prompt_path, agents_path, mcp_path):
            require(stat.S_IMODE(path.stat().st_mode) == 0o600, f"snapshot is not 0600: {path.name}")
        require(mcp_path.parent == runtime_dir, "CodeIndexer config is not session-scoped")
        require(
            json.loads(mcp_path.read_text(encoding="utf-8"))
            == {"mcpServers": {"codeindexer": {"type": "http", "url": "http://127.0.0.1:8978/mcp"}}},
            "CodeIndexer snapshot is not minimal",
        )
        require(json.loads(agents_path.read_text(encoding="utf-8")) == agents, "Claude did not receive roster snapshot")
        registration_dir = runtime_dir.parent
        require(
            (registration_dir / "runtime_schema_version").read_text(encoding="utf-8").strip() == "4",
            "schema file drift",
        )
        require(
            (registration_dir / "runtime_version").read_text(encoding="utf-8").strip() == "0.3.1",
            "runtime version drift",
        )
        hook_path = runtime_dir / "worker-subagent-contract.zsh"
        router_path = runtime_dir / "worker-agent-router.zsh"
        compaction_path = runtime_dir / "worker-compaction-counter.zsh"
        codeindexer_guard_path = runtime_dir / "worker-codeindexer-guard.zsh"
        require(stat.S_IMODE(hook_path.stat().st_mode) == 0o700, "hook snapshot is not 0700")
        require(stat.S_IMODE(router_path.stat().st_mode) == 0o700, "router snapshot is not 0700")
        require(stat.S_IMODE(compaction_path.stat().st_mode) == 0o700, "compaction snapshot is not 0700")
        require(stat.S_IMODE(codeindexer_guard_path.stat().st_mode) == 0o700, "CodeIndexer guard is not 0700")
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        require(settings["permissions"].get("defaultMode") == "auto", "Claude parent auto mode drift")
        hook_command = settings["hooks"]["SubagentStart"][0]["hooks"][0]["command"]
        require(
            shlex.split(hook_command) == [zsh, str(hook_path)],
            "settings hook is not pinned to the snapshot",
        )
        router_config = settings["hooks"]["PreToolUse"][0]
        require(router_config["matcher"] == "Agent", "router hook does not match Agent")
        router_command = router_config["hooks"][0]["command"]
        require(
            shlex.split(router_command) == [zsh, str(router_path)],
            "settings router is not pinned to the snapshot",
        )
        codeindexer_config = settings["hooks"]["PreToolUse"][1]
        require(codeindexer_config["matcher"] == "mcp__codeindexer__.*", "CodeIndexer hook matcher drift")
        codeindexer_command = codeindexer_config["hooks"][0]["command"]
        require(
            shlex.split(codeindexer_command) == [zsh, str(codeindexer_guard_path)],
            "settings CodeIndexer guard is not pinned to the snapshot",
        )
        compact_command = settings["hooks"]["PostCompact"][0]["hooks"][0]["command"]
        context_dir = registration_dir / "context"
        require(
            shlex.split(compact_command) == [zsh, str(compaction_path), str(context_dir)],
            "PostCompact hook is not pinned to this registration",
        )
        require(stat.S_IMODE(context_dir.stat().st_mode) == 0o700, "context directory is not 0700")
        for path in context_dir.iterdir():
            require(stat.S_IMODE(path.stat().st_mode) == 0o600, f"context state is not 0600: {path.name}")
        deny_rules = settings["permissions"]["deny"]
        require(
            f"Edit(/{home}/.claude/**)" in deny_rules and f"Edit(/{repo}/.codex/**)" in deny_rules,
            "absolute config deny rules are not rooted with the documented double-slash syntax",
        )
        require(not (home / ".claude").exists(), "launcher created or modified standalone Claude config")

        # Ownership, not exclusivity: a second Codex-owned worker may run in the
        # same canonical root at the same time, holding its own session-keyed
        # lease. Nothing about the first worker blocks it.
        contender_env = env.copy()
        contender_env["FAKE_CLAUDE_RECORD"] = str(base / "contender-record.json")
        contender_env.pop("FAKE_CLAUDE_CHILD_PID")
        contender, contender_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=contender_env)
        contender_output = read_pty(contender, contender_master, needle="CODEX_PTY_WORKER_READY")
        require(
            "CODEX_PTY_WORKER_READY" in contender_output,
            f"same-root sibling worker was rejected: {contender_output}",
        )
        contender_ready = json.loads(
            next(line for line in contender_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        contender_uuid = contender_ready["uuid"]
        contender_lease = Path(contender_ready["lease"])
        require(contender_uuid != worker_uuid, "sibling worker reused the first session UUID")
        require(contender_lease != lease, "two simultaneous same-root workers shared one lease")
        require(
            lease.is_dir() and contender_lease.is_dir(),
            "a simultaneous same-root worker did not hold its own durable lease",
        )
        require(
            lease.name == worker_uuid and contender_lease.name == contender_uuid,
            f"leases are not keyed by session UUID: {lease.name} {contender_lease.name}",
        )
        require(
            (contender_lease / "session_uuid").read_text(encoding="utf-8").strip() == contender_uuid,
            "sibling lease does not record its own session identity",
        )
        require(process_is_live(contender.pid), "sibling worker did not stay live alongside the first worker")

        # A foreign Codex thread may not steer this live sibling session.
        foreign_thread_env = env.copy()
        foreign_thread_env["CODEX_THREAD_ID"] = "foreign-thread"
        foreign_assign = run_assign(zsh, repo, contender_uuid, "stolen-task", foreign_thread_env)
        require(
            foreign_assign.returncode == 77
            and "CLAUDE_ASSIGN_OWNERSHIP_UNPROVEN" in foreign_assign.stderr,
            f"a foreign thread controlled an existing UUID: {foreign_assign}",
        )
        foreign_rotate = run_rotate(zsh, repo, contender_uuid, "stolen-task", foreign_thread_env)
        require(
            foreign_rotate.returncode == 77
            and "CLAUDE_ROTATE_OWNERSHIP_UNPROVEN" in foreign_rotate.stderr,
            f"a foreign thread rotated an existing UUID: {foreign_rotate}",
        )
        foreign_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), contender_uuid, "stolen-task"],
            cwd=repo,
            env=foreign_thread_env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            foreign_retire.returncode == 77
            and "CLAUDE_RETIRE_OWNERSHIP_UNPROVEN" in foreign_retire.stderr,
            f"a foreign thread retired an existing UUID: {foreign_retire}",
        )

        # The owning thread may not resume a UUID whose session is still live.
        duplicate_env = env.copy()
        duplicate_env["FAKE_CLAUDE_RECORD"] = str(base / "duplicate-resume-record.json")
        duplicate_env.pop("FAKE_CLAUDE_CHILD_PID")
        duplicate, duplicate_master = start_pty(
            [zsh, str(LAUNCHER), str(repo), "--resume", contender_uuid], cwd=repo, env=duplicate_env
        )
        duplicate_output = read_pty(duplicate, duplicate_master, timeout=10)
        duplicate.wait(timeout=5)
        os.close(duplicate_master)
        require(
            duplicate.returncode == 75 and "CLAUDE_RESUME_WORKER_STILL_LIVE" in duplicate_output,
            f"duplicate resume of a live UUID was accepted: {duplicate_output}",
        )
        require(contender_lease.is_dir(), "rejected duplicate resume damaged the live lease")

        contender.terminate()
        contender.wait(timeout=5)
        os.close(contender_master)

        # A standalone Claude belongs to another principal. It is visible under
        # the worker's own canonical root and must neither be adopted nor treated
        # as a launch conflict.
        standalone_dir = base / "standalone bin"
        standalone_dir.mkdir()
        # A symlink keeps the signed system binary runnable while making the
        # process visible as "claude", which is exactly what the removed
        # cwd scan matched on.
        standalone_claude = standalone_dir / "claude"
        standalone_claude.symlink_to("/bin/sleep")
        standalone = subprocess.Popen([str(standalone_claude), "300"], cwd=repo)
        try:
            observed_comm = subprocess.run(
                ["ps", "-ww", "-p", str(standalone.pid), "-o", "comm="],
                text=True,
                capture_output=True,
                check=False,
            ).stdout.strip()
            require(
                Path(observed_comm).name == "claude",
                f"standalone fixture is not visible as a claude process: {observed_comm!r}",
            )
            standalone_cwd = subprocess.run(
                ["lsof", "-a", "-p", str(standalone.pid), "-d", "cwd", "-Fn"],
                text=True,
                capture_output=True,
                check=False,
            ).stdout
            require(
                str(repo) in standalone_cwd,
                "standalone fixture is not rooted in the worker's canonical root",
            )
            bystander_env = env.copy()
            bystander_env["FAKE_CLAUDE_RECORD"] = str(base / "bystander-record.json")
            bystander_env.pop("FAKE_CLAUDE_CHILD_PID")
            bystander, bystander_master = start_pty(
                [zsh, str(LAUNCHER), str(repo)], cwd=repo, env=bystander_env
            )
            bystander_output = read_pty(bystander, bystander_master, needle="CODEX_PTY_WORKER_READY")
            require(
                "CODEX_PTY_WORKER_READY" in bystander_output,
                f"a standalone Claude in the same root blocked a launch: {bystander_output}",
            )
            require(
                "CLAUDE_CWD_CONFLICT" not in bystander_output,
                "launcher still reports a standalone cwd conflict",
            )
            bystander.terminate()
            bystander.wait(timeout=5)
            os.close(bystander_master)
            require(process_is_live(standalone.pid), "launcher signalled a standalone Claude process")
        finally:
            if standalone.poll() is None:
                standalone.terminate()
                standalone.wait(timeout=5)
        require(not process_is_live(standalone.pid), "standalone fixture outlived the test")

        # A legacy root-keyed lease stays usable by the session that owns it,
        # and a root-keyed plus session-keyed pair claiming one UUID is
        # ambiguous and must fail closed rather than pick a winner.
        repo_path_hash = hashlib.sha256(str(repo).encode()).hexdigest()
        legacy_layout_lease = lease.parent / repo_path_hash
        shutil.move(str(lease), str(legacy_layout_lease))
        legacy_layout_assign = run_assign(zsh, repo, worker_uuid, "legacy-lease-task", env)
        require(
            legacy_layout_assign.returncode == 0,
            f"a legacy root-keyed lease was unusable by its owner: {legacy_layout_assign}",
        )
        shutil.copytree(legacy_layout_lease, lease)
        ambiguous_assign = run_assign(zsh, repo, worker_uuid, "ambiguous-task", env)
        require(
            ambiguous_assign.returncode == 75
            and "CLAUDE_ASSIGN_WORKER_NOT_LIVE" in ambiguous_assign.stderr,
            f"ambiguous lease state did not fail closed on assignment: {ambiguous_assign}",
        )
        ambiguous_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "ambiguous-task"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            ambiguous_retire.returncode == 75
            and "CLAUDE_RETIRE_WORKER_STILL_LIVE" in ambiguous_retire.stderr,
            f"ambiguous lease state did not fail closed on retirement: {ambiguous_retire}",
        )
        shutil.rmtree(legacy_layout_lease)
        require(lease.is_dir(), "session-keyed lease was not restored")

        # The gate is driven only by completed compactions. It stores one
        # content-free line per event and one acknowledged generation.
        first_assignment = run_assign(zsh, repo, worker_uuid, "first-task", env)
        require(first_assignment.returncode == 0, f"fresh assignment was refused: {first_assignment}")

        summary_sentinel = "SUMMARY-SENTINEL-MUST-NOT-PERSIST"
        compact_payload = json.dumps(
            {
                "hook_event_name": "PostCompact",
                "session_id": worker_uuid,
                "trigger": "auto",
                "compact_summary": summary_sentinel,
            }
        )
        for _ in range(2):
            observed_compact = subprocess.run(
                [zsh, str(compaction_path), str(context_dir)],
                input=compact_payload,
                text=True,
                capture_output=True,
                check=False,
            )
            require(
                observed_compact.returncode == 0
                and summary_sentinel not in observed_compact.stdout
                and summary_sentinel not in observed_compact.stderr,
                "PostCompact observer exposed its payload",
            )
        require(
            (context_dir / "compactions.log").read_text(encoding="utf-8") == "1\n1\n",
            "completed compactions were not counted append-only",
        )
        persisted = subprocess.run(
            ["grep", "-rl", summary_sentinel, str(home)], text=True, capture_output=True, check=False
        )
        require(not persisted.stdout.strip(), f"compact summary was persisted: {persisted.stdout}")

        gated = run_assign(zsh, repo, worker_uuid, "post-compact-task", env)
        require(
            gated.returncode == 76 and "CLAUDE_ASSIGN_DECISION_REQUIRED" in gated.stderr,
            f"compaction threshold did not close the normal path: {gated}",
        )
        decision = marker_payload(gated, "CODEX_PTY_WORKER_DECISION")
        require(decision["compactions"] == 2 and decision["threshold"] == 2, f"gate marker drift: {decision}")

        continued = run_assign(
            zsh, repo, worker_uuid, "post-compact-task", env, continue_context=True
        )
        require(continued.returncode == 0, f"context continuation was refused: {continued}")
        continued_payload = marker_payload(continued, "CODEX_PTY_WORKER_ASSIGN")
        require(
            continued_payload["continuation_scope"] == "until_next_compaction",
            f"continuation scope drift: {continued_payload}",
        )
        same_generation = run_assign(zsh, repo, worker_uuid, "related-task", env)
        require(
            same_generation.returncode == 0,
            f"acknowledged generation required per-assignment ceremony: {same_generation}",
        )

        subprocess.run(
            [zsh, str(compaction_path), str(context_dir)],
            input=compact_payload,
            text=True,
            capture_output=True,
            check=True,
        )
        next_generation = run_assign(zsh, repo, worker_uuid, "next-generation", env)
        require(next_generation.returncode == 76, "a new compaction did not reopen the decision gate")

        acknowledged_path = context_dir / "acknowledged_compactions"
        acknowledged_value = acknowledged_path.read_text(encoding="utf-8")
        acknowledged_path.write_text("corrupt\n", encoding="utf-8")
        corrupt_state = run_assign(zsh, repo, worker_uuid, "corrupt-state", env)
        require(
            corrupt_state.returncode == 70 and "CLAUDE_ASSIGN_CONTEXT_CORRUPT" in corrupt_state.stderr,
            "corrupt lifecycle state reset fail-open",
        )
        acknowledged_path.write_text(acknowledged_value, encoding="utf-8")

        events_path = context_dir / "compactions.log"
        events_path.chmod(0o400)
        failed_observer = subprocess.run(
            [zsh, str(compaction_path), str(context_dir)],
            input=compact_payload,
            text=True,
            capture_output=True,
            check=False,
        )
        events_path.chmod(0o600)
        pending = list(context_dir.glob(".compaction-pending.*"))
        require(failed_observer.returncode == 0 and len(pending) == 1, "observer append failure was not durable")
        lost_event = run_assign(zsh, repo, worker_uuid, "lost-event", env)
        require(
            lost_event.returncode == 70 and "CLAUDE_ASSIGN_CONTEXT_CORRUPT" in lost_event.stderr,
            "lost compaction remained fail-open",
        )
        pending[0].rmdir()

        # Hide the lease to prove retirement also scans the exact registered
        # process and fails closed when lease state is missing.
        hidden_lease = lease.parent / f".hidden-{lease.name}"
        lease.rename(hidden_lease)
        live_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "runtime-test"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(live_retire.returncode == 75, f"live retirement did not fail closed: {live_retire}")
        require("CLAUDE_RETIRE_WORKER_STILL_LIVE" in live_retire.stderr, "live retirement reason missing")
        hidden_lease.rename(lease)

        worker.terminate()
        worker.wait(timeout=5)
        os.close(master)
        require(process_is_live(child_pid), "fake descendant did not survive the parent for custody testing")

        descendant_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "runtime-test"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(descendant_retire.returncode == 75, "retirement ignored a surviving process-group descendant")
        require("CLAUDE_RETIRE_WORKER_STILL_LIVE" in descendant_retire.stderr, "descendant reason missing")
        os.killpg(worker.pid, signal.SIGTERM)
        wait_for_process_exit(child_pid)

        wrong_thread_env = env.copy()
        wrong_thread_env["CODEX_THREAD_ID"] = "different-thread"
        wrong_thread_env["FAKE_CLAUDE_RECORD"] = str(base / "wrong-thread-record.json")
        wrong_thread_env.pop("FAKE_CLAUDE_CHILD_PID")
        wrong_thread, wrong_thread_master = start_pty(
            [zsh, str(LAUNCHER), str(repo), "--resume", worker_uuid], cwd=repo, env=wrong_thread_env
        )
        wrong_thread_output = read_pty(wrong_thread, wrong_thread_master, timeout=10)
        wrong_thread.wait(timeout=5)
        os.close(wrong_thread_master)
        require(
            wrong_thread.returncode == 77 and "CLAUDE_RESUME_OWNERSHIP_UNPROVEN" in wrong_thread_output,
            "another Codex thread resumed the worker",
        )

        resume_record = base / "resume record.json"
        resume_env = env.copy()
        resume_env.update(
            {
                "FAKE_CLAUDE_RECORD": str(resume_record),
                "CODEX_CLAUDE_PARENT_MODEL": "haiku",
                "CODEX_CLAUDE_SUBAGENT_MODEL": "opus",
            }
        )
        resume_env.pop("FAKE_CLAUDE_CHILD_PID")
        saved_claude_state = home / ".claude.json.saved"
        claude_state.rename(saved_claude_state)
        resumed, resumed_master = start_pty(
            [zsh, str(LAUNCHER), str(repo), "--resume", worker_uuid], cwd=repo, env=resume_env
        )
        resumed_output = read_pty(resumed, resumed_master, needle="CODEX_PTY_WORKER_READY")
        require("CODEX_PTY_WORKER_READY" in resumed_output, f"worker did not resume: {resumed_output}")
        resumed_ready_line = next(
            (line for line in resumed_output.splitlines() if "CODEX_PTY_WORKER_READY " in line), ""
        )
        resumed_ready = json.loads(resumed_ready_line.split("CODEX_PTY_WORKER_READY ", 1)[1].strip())
        require(resumed_ready["uuid"] == worker_uuid and resumed_ready["mode"] == "resume", "resume identity drift")
        wait_for(resume_record)
        resumed_observed = json.loads(resume_record.read_text(encoding="utf-8"))
        resumed_argv = resumed_observed["argv"]
        require(option_value(resumed_argv, "--resume") == worker_uuid, "Claude resume argument drift")
        require(option_value(resumed_argv, "--model") == "opus", "resume ignored pinned parent model")
        require(resumed_observed["subagent_model"] is None, "resume inherited a global subagent model")
        require(
            resumed_ready["runtime_schema"] == "4"
            and resumed_ready["context_state"] == "decision_required"
            and resumed_ready["context_compactions"] == 3,
            f"resume lifecycle state drift: {resumed_ready}",
        )
        require(resumed_ready["agent_models"] == expected_agent_models, "resume model roster drift")
        require(json.loads(option_value(resumed_argv, "--agents")) == agents, "resume ignored pinned roster snapshot")
        require(Path(option_value(resumed_argv, "--settings")) == settings_path, "resume settings snapshot drift")
        require(Path(option_value(resumed_argv, "--mcp-config")) == mcp_path, "resume ignored pinned MCP snapshot")
        require(
            Path(option_value(resumed_argv, "--append-system-prompt-file")) == prompt_path,
            "resume prompt snapshot drift",
        )
        resumed.terminate()
        resumed.wait(timeout=5)
        os.close(resumed_master)
        saved_claude_state.rename(claude_state)

        other_record = base / "other worker record.json"
        other_child_record = base / "other worker child.pid"
        other_env = env.copy()
        other_env["FAKE_CLAUDE_RECORD"] = str(other_record)
        other_env["FAKE_CLAUDE_CHILD_PID"] = str(other_child_record)
        other_worker, other_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=other_env)
        other_output = read_pty(other_worker, other_master, needle="CODEX_PTY_WORKER_READY")
        require("CODEX_PTY_WORKER_READY" in other_output, f"second worker did not become ready: {other_output}")
        wait_for(other_record)
        wait_for(other_child_record)
        other_child_pid = int(other_child_record.read_text(encoding="utf-8"))

        # The first worker is dead and the second is live in the same root.
        # Retirement targets only the named session, so it succeeds, and the
        # live sibling keeps its own lease and process group untouched.
        other_ready = json.loads(
            next(line for line in other_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        other_uuid = other_ready["uuid"]
        other_lease = Path(other_ready["lease"])
        require(other_uuid != worker_uuid and other_lease != lease, "sibling worker did not get a distinct lease")
        overlap_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "runtime-test"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            overlap_retire.returncode == 0,
            f"a live same-root sibling blocked retirement of a dead worker: {overlap_retire}",
        )
        require("CODEX_PTY_WORKER_RETIRED" in overlap_retire.stdout, "same-root retirement marker missing")
        require(process_is_live(other_worker.pid), "retiring one worker killed its same-root sibling")
        require(other_lease.is_dir(), "retiring one worker removed a sibling's lease")
        require(process_is_live(other_child_pid), "retiring one worker killed a sibling descendant")

        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            stopped = subprocess.run(
                [zsh, str(TOGGLE), "off", "--stop"], env=env, text=True, capture_output=True, check=False
            )
            require(stopped.returncode == 0, f"kill switch did not stop registered worker: {stopped.stderr}")
            other_worker.wait(timeout=5)
            wait_for_process_exit(other_child_pid)
            require(sleeper.poll() is None, "kill switch terminated an unrelated process")
        finally:
            if other_worker.poll() is None:
                other_worker.terminate()
                other_worker.wait(timeout=5)
            os.close(other_master)
            if sleeper.poll() is None:
                sleeper.terminate()
                sleeper.wait(timeout=5)

        subprocess.run([zsh, str(TOGGLE), "on"], env=env, check=True, capture_output=True)
        retired = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "runtime-test"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(retired.returncode == 0, f"retirement was not idempotent for the same task: {retired.stderr}")
        require("CODEX_PTY_WORKER_RETIRED" in retired.stdout, "retirement marker missing")

        retired_resume, retired_resume_master = start_pty(
            [zsh, str(LAUNCHER), str(repo), "--resume", worker_uuid], cwd=repo, env=env
        )
        retired_resume_output = read_pty(retired_resume, retired_resume_master, timeout=10)
        retired_resume.wait(timeout=5)
        os.close(retired_resume_master)
        require(
            retired_resume.returncode == 77 and "CLAUDE_RESUME_RETIRED" in retired_resume_output,
            "retired assignment resumed",
        )

        # Optional rotation is a custody transition, not an automatic response
        # to a counter. It requires process death and records explicit lineage attempts.
        rotation_repo = base / "rotation repo"
        rotation_repo.mkdir()
        subprocess.run([git, "init", "-q", "-b", "main", str(rotation_repo)], check=True)
        rotation_env = env.copy()
        rotation_env.pop("FAKE_CLAUDE_CHILD_PID", None)
        rotation_env["FAKE_CLAUDE_RECORD"] = str(base / "rotation record.json")
        rotation_worker, rotation_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo)], cwd=rotation_repo, env=rotation_env
        )
        rotation_output = read_pty(rotation_worker, rotation_master, needle="CODEX_PTY_WORKER_READY")
        rotation_ready = json.loads(
            next(line for line in rotation_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        rotation_uuid = rotation_ready["uuid"]
        live_rotation = run_rotate(zsh, rotation_repo, rotation_uuid, "rotation-task", rotation_env)
        require(
            live_rotation.returncode == 75 and "CLAUDE_ROTATE_WORKER_STILL_LIVE" in live_rotation.stderr,
            "rotation ignored a live process group",
        )

        # A sibling worker in the same root must not participate in this
        # session's rotation, in either direction.
        sibling_env = rotation_env.copy()
        sibling_env["FAKE_CLAUDE_RECORD"] = str(base / "rotation sibling record.json")
        sibling_worker, sibling_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo)], cwd=rotation_repo, env=sibling_env
        )
        sibling_output = read_pty(sibling_worker, sibling_master, needle="CODEX_PTY_WORKER_READY")
        require(
            "CODEX_PTY_WORKER_READY" in sibling_output,
            f"sibling worker was blocked by a live worker in the same root: {sibling_output}",
        )
        sibling_ready = json.loads(
            next(line for line in sibling_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        sibling_uuid = sibling_ready["uuid"]
        sibling_lease = Path(sibling_ready["lease"])
        require(sibling_uuid != rotation_uuid, "sibling reused the rotating session UUID")

        rotation_worker.terminate()
        rotation_worker.wait(timeout=5)
        os.close(rotation_master)

        rotated = run_rotate(zsh, rotation_repo, rotation_uuid, "rotation-task", rotation_env)
        require(
            rotated.returncode == 0,
            f"a live same-root sibling blocked rotation of a dead worker: {rotated}",
        )
        require(process_is_live(sibling_worker.pid), "rotation killed a same-root sibling")
        require(sibling_lease.is_dir(), "rotation removed a same-root sibling's lease")
        sibling_assignment = run_assign(zsh, rotation_repo, sibling_uuid, "sibling-task", sibling_env)
        require(
            sibling_assignment.returncode == 0,
            f"sibling stopped being assignable after its neighbour rotated: {sibling_assignment}",
        )
        sibling_worker.terminate()
        sibling_worker.wait(timeout=5)
        os.close(sibling_master)
        rotation_record = marker_payload(rotated, "CODEX_PTY_WORKER_ROTATED")
        require(
            rotation_record["state"] == "rotated_context"
            and rotation_record["attested"]["custody_returned"] is True,
            f"rotation record drift: {rotation_record}",
        )

        rotated_resume, rotated_resume_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo), "--resume", rotation_uuid],
            cwd=rotation_repo,
            env=rotation_env,
        )
        rotated_resume_output = read_pty(rotated_resume, rotated_resume_master, timeout=10)
        rotated_resume.wait(timeout=5)
        os.close(rotated_resume_master)
        require(
            rotated_resume.returncode == 77 and "CLAUDE_RESUME_RETIRED" in rotated_resume_output,
            "rotated UUID resumed",
        )

        successor_env = rotation_env.copy()
        successor_env["FAKE_CLAUDE_RECORD"] = str(base / "successor record.json")
        successor, successor_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo), "--successor-of", rotation_uuid],
            cwd=rotation_repo,
            env=successor_env,
        )
        successor_output = read_pty(successor, successor_master, needle="CODEX_PTY_WORKER_READY")
        successor_ready = json.loads(
            next(line for line in successor_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        require(
            successor_ready["lineage_kind"] == "attempt"
            and successor_ready["predecessor_session_uuid"] == rotation_uuid
            and successor_ready["lineage_id"] == rotation_record["lineage_id"],
            f"successor lineage drift: {successor_ready}",
        )
        successor.terminate()
        successor.wait(timeout=5)
        os.close(successor_master)

        successor_uuid = successor_ready["uuid"]
        successor_registration = home / ".codex/claude-pty-sessions" / successor_uuid
        successor_resume_env = successor_env.copy()
        successor_resume_env["FAKE_CLAUDE_RECORD"] = str(base / "successor resume record.json")
        successor_resume, successor_resume_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo), "--resume", successor_uuid],
            cwd=rotation_repo,
            env=successor_resume_env,
        )
        successor_resume_output = read_pty(
            successor_resume, successor_resume_master, needle="CODEX_PTY_WORKER_READY"
        )
        successor_resume_ready = json.loads(
            next(line for line in successor_resume_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        require(
            successor_resume_ready["lineage_kind"] == "attempt"
            and successor_resume_ready["predecessor_session_uuid"] == rotation_uuid
            and successor_resume_ready["lineage_id"] == rotation_record["lineage_id"],
            f"resumed successor lost lineage: {successor_resume_ready}",
        )
        successor_resume.terminate()
        successor_resume.wait(timeout=5)
        os.close(successor_resume_master)

        predecessor_path = successor_registration / "predecessor_session_uuid"
        lineage_path = successor_registration / "lineage_id"
        saved_predecessor = successor_registration / ".saved-predecessor"
        saved_lineage = successor_registration / ".saved-lineage"
        predecessor_path.rename(saved_predecessor)
        lineage_path.rename(saved_lineage)
        invalid_lineage, invalid_lineage_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo), "--resume", successor_uuid],
            cwd=rotation_repo,
            env=successor_resume_env,
        )
        invalid_lineage_output = read_pty(invalid_lineage, invalid_lineage_master, timeout=10)
        invalid_lineage.wait(timeout=5)
        os.close(invalid_lineage_master)
        saved_predecessor.rename(predecessor_path)
        saved_lineage.rename(lineage_path)
        require(
            invalid_lineage.returncode == 77 and "CLAUDE_RESUME_LINEAGE_INVALID" in invalid_lineage_output,
            "successor resumed after its complete lineage was removed",
        )

        retry, retry_master = start_pty(
            [zsh, str(LAUNCHER), str(rotation_repo), "--successor-of", rotation_uuid],
            cwd=rotation_repo,
            env=successor_env,
        )
        retry_output = read_pty(retry, retry_master, needle="CODEX_PTY_WORKER_READY")
        retry_ready = json.loads(
            next(line for line in retry_output.splitlines() if "CODEX_PTY_WORKER_READY " in line)
            .split("CODEX_PTY_WORKER_READY ", 1)[1]
            .strip()
        )
        require(
            retry_ready["uuid"] != successor_ready["uuid"]
            and retry_ready["lineage_kind"] == "attempt"
            and retry_ready["predecessor_session_uuid"] == rotation_uuid
            and retry_ready["lineage_id"] == rotation_record["lineage_id"],
            f"lineage retry drift: {retry_ready}",
        )
        retry.terminate()
        retry.wait(timeout=5)
        os.close(retry_master)

        off = subprocess.run([zsh, str(TOGGLE), "off"], env=env, text=True, capture_output=True, check=False)
        require(off.returncode == 0 and "transport is blocked" in off.stdout, "kill switch could not be enabled")
        blocked, blocked_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=env)
        blocked_output = read_pty(blocked, blocked_master, timeout=10)
        blocked.wait(timeout=5)
        os.close(blocked_master)
        require(blocked.returncode == 78 and "CLAUDE_AGENTS_DISABLED" in blocked_output, "kill switch did not block launch")

        no_thread_env = env.copy()
        no_thread_env.pop("CODEX_THREAD_ID")
        subprocess.run([zsh, str(TOGGLE), "on"], env=no_thread_env, check=True, capture_output=True)
        no_thread, no_thread_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=no_thread_env)
        no_thread_output = read_pty(no_thread, no_thread_master, timeout=10)
        no_thread.wait(timeout=5)
        os.close(no_thread_master)
        require(no_thread.returncode == 69 and "CODEX_THREAD_ID_MISSING" in no_thread_output, "thread preflight missing")

        # A published v0.1 schema-1 registration keeps its pinned single-model
        # behavior on resume instead of being silently migrated to schema 2.
        legacy_repo = base / "legacy schema repo"
        legacy_repo.mkdir()
        subprocess.run([git, "init", "-q", "-b", "main", str(legacy_repo)], check=True)
        legacy_uuid = str(uuid.uuid4())
        legacy_path_hash = hashlib.sha256(str(legacy_repo).encode()).hexdigest()
        legacy_thread_hash = hashlib.sha256(env["CODEX_THREAD_ID"].encode()).hexdigest()
        legacy_registration = home / ".codex/claude-pty-sessions" / legacy_uuid
        legacy_runtime = legacy_registration / "runtime"
        legacy_runtime.mkdir(parents=True, mode=0o700)
        legacy_fields = {
            "owner_kind": "codex-pty-worker",
            "root": str(legacy_repo),
            "path_hash": legacy_path_hash,
            "thread_hash": legacy_thread_hash,
            "session_uuid": legacy_uuid,
            "name": "legacy-schema-worker",
            "process_group": "999999",
            "created_at": "fixture",
            "runtime_schema_version": "1",
            "runtime_version": "0.1.0",
            "parent_model": "opus",
            "subagent_model": "haiku",
        }
        for field, value in legacy_fields.items():
            (legacy_registration / field).write_text(value + "\n", encoding="utf-8")
        legacy_settings = legacy_runtime / "worker-settings.json"
        legacy_prompt = legacy_runtime / "worker-system-prompt.txt"
        legacy_hook = legacy_runtime / "worker-subagent-contract.zsh"
        legacy_settings.write_text("{}\n", encoding="utf-8")
        legacy_prompt.write_text("legacy snapshot\n", encoding="utf-8")
        legacy_hook.write_text("#!/usr/bin/env zsh\nexit 0\n", encoding="utf-8")
        legacy_settings.chmod(0o600)
        legacy_prompt.chmod(0o600)
        legacy_hook.chmod(0o700)

        legacy_record = base / "legacy resume record.json"
        legacy_env = env.copy()
        legacy_env["FAKE_CLAUDE_RECORD"] = str(legacy_record)
        legacy_env["CODEX_CLAUDE_PARENT_MODEL"] = "sonnet"
        legacy_env["CODEX_CLAUDE_SUBAGENT_MODEL"] = "opus"
        legacy_env.pop("FAKE_CLAUDE_CHILD_PID")
        legacy_worker, legacy_master = start_pty(
            [zsh, str(LAUNCHER), str(legacy_repo), "--resume", legacy_uuid],
            cwd=legacy_repo,
            env=legacy_env,
        )
        legacy_output = read_pty(legacy_worker, legacy_master, needle="CODEX_PTY_WORKER_READY")
        require("CODEX_PTY_WORKER_READY" in legacy_output, f"schema-1 worker did not resume: {legacy_output}")
        legacy_ready_line = next(
            (line for line in legacy_output.splitlines() if "CODEX_PTY_WORKER_READY " in line), ""
        )
        legacy_ready = json.loads(legacy_ready_line.split("CODEX_PTY_WORKER_READY ", 1)[1].strip())
        require(legacy_ready["runtime_schema"] == "1", "legacy resume was silently migrated")
        require(legacy_ready["agent_models"] == {"*": "haiku"}, "legacy model snapshot drift")
        require(legacy_ready["context_state"] == "unobserved_legacy", "legacy context was claimed fresh")
        legacy_gate = run_assign(zsh, legacy_repo, legacy_uuid, "legacy-task", legacy_env)
        require(
            legacy_gate.returncode == 0
            and marker_payload(legacy_gate, "CODEX_PTY_WORKER_ASSIGN")["context_state"]
            == "unobserved_legacy",
            "legacy session lost productive reuse or was claimed fresh",
        )
        wait_for(legacy_record)
        legacy_observed = json.loads(legacy_record.read_text(encoding="utf-8"))
        legacy_argv = legacy_observed["argv"]
        require(option_value(legacy_argv, "--model") == "opus", "legacy parent snapshot drift")
        require(legacy_observed["subagent_model"] == "haiku", "legacy subagent snapshot drift")
        require(legacy_observed["disable_explore_plan"] is None, "legacy built-in routing changed")
        require("--agents" not in legacy_argv, "legacy resume received a schema-2 roster")
        require("--mcp-config" not in legacy_argv, "legacy resume was silently given CodeIndexer")
        legacy_worker.terminate()
        legacy_worker.wait(timeout=5)
        os.close(legacy_master)

        agent_dir = repo / ".codex/agents"
        dry_run = subprocess.run(
            [zsh, str(SETUP), "--target", "project", "--root", str(repo)],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(dry_run.returncode == 0 and "DRY_RUN: no files written" in dry_run.stdout, "native setup dry run failed")
        expected_native_models = {
            "source_explorer": "gpt-5.6-luna",
            "test_runner": "gpt-5.6-luna",
            "mech_executor": "gpt-5.6-terra",
            "reviewer": "gpt-5.6-terra",
            "security_reviewer": "gpt-5.6-sol",
        }
        for role, model in expected_native_models.items():
            require(f"{role}.toml (model={model})" in dry_run.stdout, f"dry-run model drift: {role}")
        require(not agent_dir.exists(), "native setup dry run wrote configuration")
        override_preview = subprocess.run(
            [
                zsh,
                str(SETUP),
                "--target",
                "project",
                "--root",
                str(repo),
                "--model",
                "uniform-model",
                "--role-model",
                "reviewer=review-model",
            ],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(override_preview.returncode == 0, f"native override preview failed: {override_preview.stderr}")
        require("reviewer.toml (model=review-model)" in override_preview.stdout, "role override lost precedence")
        for role in expected_native_models.keys() - {"reviewer"}:
            require(f"{role}.toml (model=uniform-model)" in override_preview.stdout, f"uniform override drift: {role}")
        applied = subprocess.run(
            [zsh, str(SETUP), "--target", "project", "--root", str(repo), "--apply", "--yes"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(applied.returncode == 0, f"native setup apply failed: {applied.stderr}")
        installed = sorted(path.name for path in agent_dir.glob("*.toml"))
        require(
            installed == [
                "mech_executor.toml",
                "reviewer.toml",
                "security_reviewer.toml",
                "source_explorer.toml",
                "test_runner.toml",
            ],
            f"unexpected native role set: {installed}",
        )
        installed_native_models = {
            path.stem: re.search(
                r'^model = "([^"]+)"$', path.read_text(encoding="utf-8"), re.MULTILINE
            ).group(1)
            for path in agent_dir.glob("*.toml")
        }
        require(installed_native_models == expected_native_models, f"native default model map drift: {installed_native_models}")

        trusted_applied = subprocess.run(
            [zsh, str(SETUP), "--target", "user", "--apply", "--yes"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(trusted_applied.returncode == 0, f"trusted native setup failed: {trusted_applied.stderr}")
        trusted_agent_dir = home / ".codex/agents"
        require(
            sorted(path.name for path in trusted_agent_dir.glob("*.toml")) == installed,
            "trusted native role set drift",
        )

        project_source_profile = agent_dir / "source_explorer.toml"
        project_source_text = project_source_profile.read_text(encoding="utf-8")
        project_source_profile.write_text(
            project_source_text.replace('model = "gpt-5.6-luna"', 'model = "untrusted-project-model"'),
            encoding="utf-8",
        )

        fake_codex = base / "fake codex"
        write_fake_codex(fake_codex)
        codex_record = base / "native codex record.json"
        native_env = env.copy()
        native_env["CODEX_NATIVE_EXECUTABLE"] = str(fake_codex)
        native_env["FAKE_CODEX_RECORD"] = str(codex_record)
        source_task = "inspect the bounded source path"
        isolated_source = subprocess.run(
            [zsh, str(NATIVE_RUNNER), "source_explorer", str(repo)],
            cwd=repo,
            env=native_env,
            input=source_task,
            text=True,
            capture_output=True,
            check=False,
        )
        require(isolated_source.returncode == 0, f"isolated source launch failed: {isolated_source.stderr}")
        require(
            "CODEX_NATIVE_ISOLATED_START role=source_explorer sandbox=read-only" in isolated_source.stderr
            and "index=codeindexer-readonly" in isolated_source.stderr,
            "isolated indexed source marker drift",
        )
        source_record = json.loads(codex_record.read_text(encoding="utf-8"))
        source_argv = source_record["argv"]
        require(source_argv[0] == "exec", "isolated native launcher did not use codex exec")
        require(option_value(source_argv, "--sandbox") == "read-only", "source explorer sandbox was not enforced")
        require(option_value(source_argv, "--model") == "gpt-5.6-luna", "source explorer model drift")
        project_source_profile.write_text(project_source_text, encoding="utf-8")
        require(option_value(source_argv, "--cd") == str(repo), "isolated native root drift")
        for option in ("--ephemeral", "--ignore-user-config"):
            require(option in source_argv, f"isolated native option missing: {option}")
        for feature in ("multi_agent", "apps", "hooks"):
            require(
                any(source_argv[index : index + 2] == ["--disable", feature] for index in range(len(source_argv) - 1)),
                f"isolated native feature remains enabled: {feature}",
            )
        configs = [
            source_argv[index + 1]
            for index, value in enumerate(source_argv[:-1])
            if value in ("--config", "-c")
        ]
        require('approval_policy="never"' in configs, "isolated native approval policy drift")
        require('web_search="disabled"' in configs, "isolated native web search remains enabled")
        require(
            any(
                value.startswith("developer_instructions=")
                and "Boundary:" in value
                and "task supplies the exact indexed project name" in value
                for value in configs
            ),
            "isolated native role instructions were not promoted",
        )
        native_mcp_configs = [value for value in configs if value.startswith("mcp_servers=")]
        require(len(native_mcp_configs) == 1, "isolated native MCP config is not singular")
        native_mcp_config = native_mcp_configs[0]
        require('url="http://127.0.0.1:8978/mcp"' in native_mcp_config, "isolated native CodeIndexer URL drift")
        require("enabled_tools=" in native_mcp_config and "disabled_tools=" in native_mcp_config, "isolated native MCP filters missing")
        enabled_segment = native_mcp_config.split("enabled_tools=", 1)[1].split(",disabled_tools=", 1)[0]
        disabled_segment = native_mcp_config.split("disabled_tools=", 1)[1].split(",default_tools_approval_mode=", 1)[0]
        for tool in ("search_code", "read_chunk", "file_deps", "find_callers", "find_test_coverage"):
            require(f'"{tool}"' in enabled_segment, f"isolated native CodeIndexer read tool missing: {tool}")
        for mixed_action_tool in ("projects", "solutions", "skills", "memory_cards"):
            require(
                f'"{mixed_action_tool}"' not in enabled_segment
                and f'"{mixed_action_tool}"' in disabled_segment,
                f"mixed-action CodeIndexer tool filter drift: {mixed_action_tool}",
            )
        require("required=true" in native_mcp_config, "isolated native CodeIndexer is not fail-closed")
        require(
            'default_tools_approval_mode="approve"' in native_mcp_config,
            "isolated native read tools still require interactive approval",
        )
        require(source_record["stdin"] == source_task, "native task did not remain stdin-only")
        require(source_task not in " ".join(source_argv), "native task leaked into process arguments")

        isolated_writer = subprocess.run(
            [zsh, str(NATIVE_RUNNER), "mech_executor", str(repo)],
            cwd=repo,
            env=native_env,
            input="make one bounded local edit",
            text=True,
            capture_output=True,
            check=False,
        )
        require(isolated_writer.returncode == 0, f"isolated writer launch failed: {isolated_writer.stderr}")
        writer_record = json.loads(codex_record.read_text(encoding="utf-8"))
        require(option_value(writer_record["argv"], "--sandbox") == "workspace-write", "writer sandbox was not bounded")

        source_profile = trusted_agent_dir / "source_explorer.toml"
        source_profile_text = source_profile.read_text(encoding="utf-8")
        source_profile.write_text(source_profile_text.replace('sandbox_mode = "read-only"', 'sandbox_mode = "workspace-write"'), encoding="utf-8")
        broadened_source = subprocess.run(
            [zsh, str(NATIVE_RUNNER), "source_explorer", str(repo)],
            cwd=repo,
            env=native_env,
            input="inspect source",
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            broadened_source.returncode == 78 and "NATIVE_ROLE_SANDBOX_MISMATCH" in broadened_source.stderr,
            "isolated native launcher accepted a broadened source profile",
        )
        source_profile.write_text(source_profile_text, encoding="utf-8")

        source_profile.write_text(
            source_profile_text.replace('model_reasoning_effort = "medium"', 'model_reasoning_effort = "low"'),
            encoding="utf-8",
        )
        drifted_source = subprocess.run(
            [zsh, str(NATIVE_RUNNER), "source_explorer", str(repo)],
            cwd=repo,
            env=native_env,
            input="inspect source",
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            drifted_source.returncode == 78 and "NATIVE_ROLE_PROFILE_CONTRACT_MISMATCH" in drifted_source.stderr,
            "isolated native launcher accepted a drifted trusted role contract",
        )
        source_profile.write_text(source_profile_text, encoding="utf-8")

        unsupported_native = subprocess.run(
            [zsh, str(NATIVE_RUNNER), "unknown_role", str(repo)],
            cwd=repo,
            env=native_env,
            input="inspect source",
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            unsupported_native.returncode == 64 and "NATIVE_ROLE_UNSUPPORTED" in unsupported_native.stderr,
            "isolated native launcher accepted an unknown role",
        )
        before = {path.name: path.read_bytes() for path in agent_dir.glob("*.toml")}
        collision = subprocess.run(
            [zsh, str(SETUP), "--target", "project", "--root", str(repo), "--apply", "--yes"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(collision.returncode == 73 and "REFUSING_TO_OVERWRITE" in collision.stderr, "native setup overwrote a collision")
        after = {path.name: path.read_bytes() for path in agent_dir.glob("*.toml")}
        require(before == after, "native role content changed after collision")

        symlink_repo = base / "symlink collision repo"
        symlink_repo.mkdir()
        subprocess.run([git, "init", "-q", "-b", "main", str(symlink_repo)], check=True)
        symlink_agent_dir = symlink_repo / ".codex/agents"
        symlink_agent_dir.mkdir(parents=True)
        dangling = symlink_agent_dir / "source_explorer.toml"
        dangling.symlink_to("missing-target.toml")
        symlink_collision = subprocess.run(
            [zsh, str(SETUP), "--target", "project", "--root", str(symlink_repo), "--apply", "--yes"],
            cwd=symlink_repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            symlink_collision.returncode == 73 and "REFUSING_TO_OVERWRITE" in symlink_collision.stderr,
            "native setup did not refuse a dangling symlink",
        )
        require(dangling.is_symlink() and os.readlink(dangling) == "missing-target.toml", "dangling symlink changed")
        require(
            sorted(path.name for path in symlink_agent_dir.iterdir()) == ["source_explorer.toml"],
            "dangling-symlink collision produced a partial setup",
        )

        concurrent_repo = base / "concurrent setup repo"
        concurrent_repo.mkdir()
        subprocess.run([git, "init", "-q", "-b", "main", str(concurrent_repo)], check=True)
        common_setup = [zsh, str(SETUP), "--target", "project", "--root", str(concurrent_repo), "--apply", "--yes"]
        first_setup = subprocess.Popen(
            [*common_setup, "--model", "cheap-a"],
            cwd=concurrent_repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        second_setup = subprocess.Popen(
            [*common_setup, "--model", "cheap-b"],
            cwd=concurrent_repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        first_output = first_setup.communicate(timeout=10)
        second_output = second_setup.communicate(timeout=10)
        outcomes = [first_setup.returncode, second_setup.returncode]
        require(outcomes.count(0) == 1 and all(code in (0, 73, 75) for code in outcomes), f"concurrent setup outcomes: {outcomes} {first_output} {second_output}")
        concurrent_agent_dir = concurrent_repo / ".codex/agents"
        concurrent_roles = sorted(concurrent_agent_dir.glob("*.toml"))
        require(len(concurrent_roles) == 5, "concurrent setup left a partial role set")
        installed_models = {
            re.search(r'^model = "([^"]+)"$', path.read_text(encoding="utf-8"), re.MULTILINE).group(1)
            for path in concurrent_roles
        }
        require(installed_models in ({"cheap-a"}, {"cheap-b"}), f"concurrent setup mixed models: {installed_models}")
        require(
            not (concurrent_agent_dir / ".codex-claude-orchestrator-install.lock").exists(),
            "concurrent setup left its destination lock",
        )

    print("runtime invariants: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"runtime invariants: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
