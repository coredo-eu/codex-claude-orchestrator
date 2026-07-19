#!/usr/bin/env python3
"""PTY lifecycle tests using a fake Claude executable and an isolated HOME."""

from __future__ import annotations

import errno
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
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "plugins/codex-claude-orchestrator/skills/claude-pty-agents/scripts"
LAUNCHER = SCRIPTS / "launch-worker.zsh"
RETIRE = SCRIPTS / "retire-native-fallback.zsh"
TOGGLE = SCRIPTS / "toggle-agents.zsh"
SETUP = SCRIPTS / "setup-native-agents.zsh"


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


def main() -> int:
    zsh = shutil.which("zsh")
    jq = shutil.which("jq")
    git = shutil.which("git")
    require(bool(zsh and jq and git), "zsh, jq, and git are required for runtime tests")

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
                "FAKE_CLAUDE_RECORD": str(record),
                "FAKE_CLAUDE_CHILD_PID": str(child_record),
            }
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
        wait_for(record)
        wait_for(child_record)
        child_pid = int(child_record.read_text(encoding="utf-8"))

        observed = json.loads(record.read_text(encoding="utf-8"))
        argv = observed["argv"]
        require(observed["cwd"] == str(repo), "fake Claude cwd drift")
        require(observed["subagent_model"] == "haiku", "Claude subagents were not forced to Haiku")
        require(observed["disable_auto_memory"] == "1", "auto-memory was not disabled")
        require(observed["disable_git_instructions"] == "1", "automatic Git instructions were not disabled")
        require(option_value(argv, "--model") == "opus", "parent model is not Opus")
        require(option_value(argv, "--setting-sources") == "", "private settings sources were loaded")
        require("--strict-mcp-config" in argv, "strict MCP mode missing")
        require("--dangerously-skip-permissions" not in argv, "permission bypass was enabled")

        settings_path = Path(option_value(argv, "--settings"))
        prompt_path = Path(option_value(argv, "--append-system-prompt-file"))
        runtime_dir = settings_path.parent
        require(str(runtime_dir).startswith(str(home / ".codex/claude-pty-sessions")), "runtime escaped private state")
        require(prompt_path.parent == runtime_dir, "worker does not use one runtime snapshot")
        require(stat.S_IMODE(runtime_dir.stat().st_mode) == 0o700, "runtime directory is not 0700")
        for path in (settings_path, prompt_path):
            require(stat.S_IMODE(path.stat().st_mode) == 0o600, f"snapshot is not 0600: {path.name}")
        hook_path = runtime_dir / "worker-subagent-contract.zsh"
        require(stat.S_IMODE(hook_path.stat().st_mode) == 0o700, "hook snapshot is not 0700")
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        hook_command = settings["hooks"]["SubagentStart"][0]["hooks"][0]["command"]
        require(
            shlex.split(hook_command) == [zsh, str(hook_path)],
            "settings hook is not pinned to the snapshot",
        )
        deny_rules = settings["permissions"]["deny"]
        require(
            f"Edit(/{home}/.claude/**)" in deny_rules and f"Edit(/{repo}/.codex/**)" in deny_rules,
            "absolute config deny rules are not rooted with the documented double-slash syntax",
        )
        require(not (home / ".claude").exists(), "launcher created or modified standalone Claude config")

        contender_env = env.copy()
        contender_env["FAKE_CLAUDE_RECORD"] = str(base / "contender-record.json")
        contender, contender_master = start_pty([zsh, str(LAUNCHER), str(repo)], cwd=repo, env=contender_env)
        contender_output = read_pty(contender, contender_master, timeout=10)
        contender.wait(timeout=5)
        os.close(contender_master)
        require(contender.returncode == 75, f"concurrent writer was not rejected: rc={contender.returncode} output={contender_output}")
        require(
            any(
                marker in contender_output
                for marker in ("LEASE_CONFLICT", "CLAUDE_CWD_CONFLICT", "REGISTRATION_PROCESS_GROUP_CONFLICT")
            ),
            f"wrong concurrent rejection: {contender_output}",
        )

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
        require(resumed_observed["subagent_model"] == "haiku", "resume ignored pinned subagent model")
        require(Path(option_value(resumed_argv, "--settings")) == settings_path, "resume settings snapshot drift")
        require(
            Path(option_value(resumed_argv, "--append-system-prompt-file")) == prompt_path,
            "resume prompt snapshot drift",
        )
        resumed.terminate()
        resumed.wait(timeout=5)
        os.close(resumed_master)

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

        overlap_retire = subprocess.run(
            [zsh, str(RETIRE), str(repo), worker_uuid, "runtime-test"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        require(overlap_retire.returncode == 75, "retirement ignored another live worker in the same scope")
        require("CLAUDE_RETIRE_WORKER_STILL_LIVE" in overlap_retire.stderr, "overlap retirement reason missing")

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
        require(retired.returncode == 0, f"dead worker could not be retired: {retired.stderr}")
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
        require(not agent_dir.exists(), "native setup dry run wrote configuration")
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
