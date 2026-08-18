#!/usr/bin/env python3
"""Credential-free deterministic repository invariant checks."""

from __future__ import annotations

import json
import os
import re
import stat
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "codex-claude-orchestrator"
SKILL = PLUGIN / "skills" / "claude-pty-agents"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    marketplace = json.loads(read(ROOT / ".agents/plugins/marketplace.json"))
    require(marketplace["name"] == "codex-claude-orchestrator", "marketplace name drift")
    require(len(marketplace["plugins"]) == 1, "marketplace must have one plugin")
    entry = marketplace["plugins"][0]
    require(entry["name"] == "codex-claude-orchestrator", "marketplace plugin name drift")
    require(
        entry["source"] == {
            "source": "local",
            "path": "./plugins/codex-claude-orchestrator",
        },
        "marketplace source must be the nested Git plugin",
    )
    require(
        entry["policy"] == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "marketplace policy drift",
    )

    manifest = json.loads(read(PLUGIN / ".codex-plugin/plugin.json"))
    require(manifest["name"] == PLUGIN.name, "plugin folder and manifest names differ")
    require(
        re.fullmatch(r"\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?", manifest["version"]) is not None,
        "strict semver required",
    )
    require(manifest["version"].startswith("0.4.0+codex."), "local cachebuster version drift")
    require(manifest["skills"] == "./skills/", "skill discovery path drift")
    require(manifest.get("license") == "MIT", "MIT manifest license required")
    repository_url = "https://github.com/coredo-eu/codex-claude-orchestrator"
    require(manifest.get("repository") == repository_url, "repository URL drift")
    require(manifest.get("homepage") == f"{repository_url}#readme", "homepage URL drift")
    require(manifest.get("author") == {"name": "Nikita Veremeev", "url": "https://github.com/coredo-eu"}, "author drift")
    require(manifest["interface"].get("websiteURL") == repository_url, "plugin website URL drift")

    skill_text = read(SKILL / "SKILL.md")
    match = re.match(r"\A---\n(.*?)\n---\n", skill_text, flags=re.DOTALL)
    require(match is not None, "skill frontmatter missing")
    frontmatter_keys = [
        line.split(":", 1)[0]
        for line in match.group(1).splitlines()
        if line and not line.startswith(" ")
    ]
    require(frontmatter_keys == ["name", "description"], "skill frontmatter must contain only name/description")
    require("name: claude-pty-agents" in match.group(1), "skill name drift")
    for marker in (
        "Codex owns the repository trust decision and does not ask the user",
        "This does not expand any other authority",
        "use `--idle` to bypass this admission path",
        "unless the user explicitly authorizes abandoning the exact",
        "inspect the preserved worktree",
    ):
        require(marker in skill_text, f"Codex-owned repository trust policy missing: {marker}")

    for marker, message in (
        ("`task_name` only", "native task identity is not separated from role routing"),
        ("`agent_type`", "native custom-agent selector missing"),
        ('`fork_turns: "all"`', "full-history native role inheritance warning missing"),
        ("`agent_role` must equal the requested `agent_type`", "native role verification missing"),
        ("stop the child and fail closed", "native role mismatch is not fail closed"),
    ):
        require(marker in skill_text, message)

    launcher = read(SKILL / "scripts/launch-worker.zsh")
    runtime = read(SKILL / "scripts/runtime-lib.zsh")
    rotate = read(SKILL / "scripts/rotate-worker.zsh")
    retire = read(SKILL / "scripts/retire-native-fallback.zsh")
    reconcile = read(SKILL / "scripts/reconcile-orphan.zsh")
    toggle = read(SKILL / "scripts/toggle-agents.zsh")
    setup = read(SKILL / "scripts/setup-native-agents.zsh")
    native_runner = read(SKILL / "scripts/run-native-agent.zsh")
    policy = read(SKILL / "references/codex-policy-snippet.md")
    agent_roster = json.loads(read(SKILL / "assets/worker-agents.json"))

    expected_agent_models = {
        "explorer": "claude-haiku-4-5-20251001",
        "log-analyzer": "claude-haiku-4-5-20251001",
        "test-triager": "claude-haiku-4-5-20251001",
        "scout": "claude-haiku-4-5-20251001",
        "implementer": "claude-sonnet-5",
        "debugger": "claude-sonnet-5",
        "reviewer": "claude-opus-5",
        "security-reviewer": "claude-opus-5",
        "long-horizon": "claude-fable-5",
    }
    expected_agent_efforts = {
        "explorer": None,
        "log-analyzer": None,
        "test-triager": None,
        "scout": None,
        "implementer": "high",
        "debugger": "xhigh",
        "reviewer": "medium",
        "security-reviewer": "xhigh",
        "long-horizon": "xhigh",
    }
    expected_agent_tools = {
        "explorer": ["Read", "Grep", "Glob", "Bash"],
        "log-analyzer": ["Read", "Grep", "Glob", "Bash"],
        "test-triager": ["Read", "Grep", "Glob", "Bash"],
        "scout": ["Read", "Grep", "Glob", "Bash"],
        "implementer": ["Read", "Grep", "Glob", "Edit", "Write", "Bash"],
        "debugger": ["Read", "Grep", "Glob", "Bash"],
        "reviewer": ["Read", "Grep", "Glob", "Bash"],
        "security-reviewer": ["Read", "Grep", "Glob", "Bash"],
        "long-horizon": ["Read", "Grep", "Glob", "Edit", "Write", "Bash"],
    }
    require(
        {name: definition.get("model") for name, definition in agent_roster.items()} == expected_agent_models,
        "Claude role model map drift",
    )
    require(
        {name: definition.get("effort") for name, definition in agent_roster.items()} == expected_agent_efforts,
        "Claude role effort map drift",
    )
    require(
        {name: definition.get("tools") for name, definition in agent_roster.items()} == expected_agent_tools,
        "Claude role tool map drift",
    )
    read_only_roles = {
        "explorer", "log-analyzer", "test-triager", "scout", "debugger", "reviewer", "security-reviewer"
    }
    require(
        {name for name, definition in agent_roster.items() if definition.get("permissionMode") == "plan"}
        == read_only_roles,
        "Claude read-only permission map drift",
    )
    require(all("Agent" not in definition["tools"] for definition in agent_roster.values()), "recursive Agent tool enabled")
    require(all(definition.get("description") and definition.get("prompt") for definition in agent_roster.values()), "Claude role contract missing")
    for name, definition in agent_roster.items():
        prompt = definition["prompt"]
        require(prompt.startswith("Outcome:"), f"Claude prompt is not outcome-first: {name}")
        for marker in ("Boundary:", "Return:", "Choose the method."):
            require(marker in prompt, f"Claude prompt contract missing {marker}: {name}")
        require(len(prompt.split()) <= 65, f"Claude prompt is no longer lean: {name}")
    expected_descriptions = {
        "explorer": "Use proactively for bounded file discovery, source search, and fact extraction when independent evidence or context isolation has net value.",
        "log-analyzer": "Use proactively for classifying logs, build output, and test results when isolating noisy evidence has net value.",
        "test-triager": "Use proactively for a read-only pass over test failures when an isolated causal assessment has net value.",
        "scout": "Use proactively for bounded local operational reconnaissance: health, logs, queues, processes, disk state, and other read-only runtime facts.",
        "implementer": "Use for ordinary bounded implementation only when isolated edit custody has net value and the parent transfers the sole edit scope.",
        "debugger": "Use for multi-step diagnosis when isolated command output and reasoning have net value; do not edit source.",
        "reviewer": "Use for independent review when a separate falsifying pass on regressions, architecture, or missing verification has net value.",
        "security-reviewer": "Use for focused security, authorization, concurrency, privacy, and recovery review when independent adversarial evidence has net value.",
        "long-horizon": "Use only after an explicit long-horizon route and explicit sole edit custody for an exceptionally large autonomous outcome; Fable is preferred and Opus is the availability fallback.",
    }
    require(
        {role: agent_roster[role]["description"] for role in expected_descriptions} == expected_descriptions,
        "Claude role descriptions lost their cost-aware semantic routing",
    )

    worker_prompt = read(SKILL / "assets/worker-system-prompt.txt")
    require(worker_prompt.startswith("Outcome:"), "worker prompt is not outcome-first")
    for heading in ("Authority:", "Boundaries:", "Roster:", "Handoff:"):
        require(heading in worker_prompt, f"worker prompt contract missing {heading}")
    require("choose the method" in worker_prompt.casefold(), "worker prompt does not grant method choice")
    require("launcher enforces their roles and models" in worker_prompt, "runtime routing boundary missing")
    require("Read-only Haiku roles may be chosen" in worker_prompt, "cost-aware proactive delegation missing")
    require("Sonnet and Opus roles follow their specific descriptions" in worker_prompt, "expensive role routing is not bounded")
    require("Roles are routes, not a mandatory pipeline" in worker_prompt, "optional role topology missing")
    require("checkpoint neither" in worker_prompt and "transfers custody" in worker_prompt, "checkpoint authority boundary missing")
    require(len(worker_prompt.split()) <= 290, "worker prompt is no longer lean")
    headings = ("Outcome", "Done when", "Boundaries", "Authoritative context", "Non-goals", "Known evidence", "Required handoff")
    heading_contract = worker_prompt.split("The assignment body preserves these headings verbatim and in this order:", 1)[1]
    positions = [heading_contract.index(heading) for heading in headings]
    require(positions == sorted(positions), "assignment headings are not preserved in order")
    require("persistent outer goal" in worker_prompt and "never goal completion" in worker_prompt, "outer-goal authority missing")
    assignment_block = re.search(r"TASK_ID: <unique-id>\n\n(.*?)\n```", skill_text, flags=re.DOTALL)
    require(assignment_block is not None, "SKILL assignment block missing")
    require(re.findall(r"^(Outcome|Done when|Boundaries|Authoritative context|Non-goals|Known evidence|Required handoff):$", assignment_block.group(1), flags=re.MULTILINE) == list(headings), "SKILL assignment headings drifted")

    hook_text = read(SKILL / "scripts/worker-subagent-contract.zsh")
    router_text = read(SKILL / "scripts/worker-agent-router.zsh")
    stage_guard_text = read(SKILL / "scripts/worker-stage-guard.zsh")
    hook_context = re.search(r"context='([^']+)'", hook_text)
    require(hook_context is not None, "subagent hook context missing")
    require("choose the method" in hook_context.group(1).casefold(), "subagent hook prescribes method")
    require(len(hook_context.group(1).split()) <= 100, "subagent hook context is no longer lean")
    for role, model in expected_agent_models.items():
        require(role in router_text and model in router_text, f"router mapping missing: {role}")
    require('"permissionDecision":"deny"' in router_text, "router lacks a blocking decision")
    require("subagent_type" in router_text, "router does not inspect the requested role")
    for marker in (
        'permissionDecision:"deny"',
        "cache_read_input_tokens",
        "request_keys.log",
        "agent_id",
        "agent_calls_by_role",
        "checkpoint.json",
        "This checkpoint is not outer-goal completion",
        "max_parent_tool_calls",
    ):
        require(marker in stage_guard_text, f"parent-stage checkpoint contract missing: {marker}")
    require("message.content" not in stage_guard_text, "stage guard inspects transcript content")

    require(
        "CODEX_CLAUDE_PARENT_MODEL:-claude-sonnet-5" in launcher,
        "Claude Sonnet 5 parent default missing",
    )
    require("CODEX_CLAUDE_PARENT_EFFORT:-high" in launcher, "high Claude parent effort default missing")
    require("OPUS_PARENT_ROUTE_REQUIRED" in launcher and "parent_route_reason" in launcher, "auditable Opus routing missing")
    require("CODEX_CLAUDE_SUBAGENT_MODEL:-" not in launcher, "legacy global Claude model configuration remains")
    require("-u CLAUDE_CODE_SUBAGENT_MODEL" in launcher, "inherited global Claude model override is not cleared")
    require("-u CLAUDE_CODE_EFFORT_LEVEL" in launcher, "inherited global Claude effort override is not cleared")
    require('--agents "$agents_json"' in launcher, "session-scoped Claude roster missing")
    require("CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1" in launcher, "built-in Explore/Plan disable missing")
    for agent in ("Explore", "Plan", "general-purpose", "statusline-setup", "claude-code-guide"):
        require(f"Agent({agent})" in launcher, f"built-in Claude agent is not denied: {agent}")
    require('--model "$parent_model"' in launcher, "parent model CLI pin missing")
    require('--effort "$parent_effort"' in launcher, "parent effort CLI pin missing")
    require('--setting-sources ""' in launcher, "isolated setting sources missing")
    require('defaultMode: "auto"' in launcher, "Claude parent auto mode missing")
    require("--strict-mcp-config" in launcher, "external MCP configurations are not excluded")
    require("--mcp-config" not in launcher, "launcher must not inject an MCP configuration")

    require("runtime_schema_version" in launcher and 'print -r -- "5"' in launcher, "runtime schema-5 pin missing")
    require('print -r -- "0.4.0" > "$registration/runtime_version"' in launcher, "runtime schema-5 version drift")
    for snapshot in (
        "worker-agents.json",
        "worker-system-prompt.txt",
        "worker-subagent-contract.zsh",
        "worker-agent-router.zsh",
        "worker-compaction-counter.zsh",
        "worker-stage-guard.zsh",
        "worker-settings.json",
    ):
        require(f'runtime/{snapshot}' in launcher or f'runtime_dir/{snapshot}' in launcher or snapshot in launcher, f"snapshot missing: {snapshot}")
    require('--append-system-prompt-file "$runtime_prompt"' in launcher, "live worker does not use prompt snapshot")
    require("$runtime_hook" in launcher, "generated settings do not pin hook snapshot")
    require("$runtime_agent_router" in launcher, "generated settings do not pin router snapshot")
    require("$runtime_compaction_counter" in launcher, "generated settings do not pin PostCompact observer")
    require("$runtime_stage_guard" in launcher and 'matcher: "*"' in launcher, "generated settings do not pin parent-stage guard")
    require("CODEX_CLAUDE_STAGE_WARN_PARENT_TOOL_CALLS:-128" in launcher and "CODEX_CLAUDE_STAGE_MAX_PARENT_TOOL_CALLS:-256" in launcher, "parent-tool fallback defaults missing")
    require("PostCompact" in launcher, "completed compactions are not observed")
    require("/bin/chmod 700 \"$runtime_dir\"" in launcher, "runtime directory mode missing")
    require("/bin/chmod 600 \"$runtime_prompt\"" in launcher, "prompt snapshot mode missing")

    require("CLAUDE_RESUME_RETIRED" in launcher, "retired resume rejection missing")
    require("CLAUDE_RESUME_OWNERSHIP_UNPROVEN" in launcher, "thread/root resume validation missing")
    require("CODEX_THREAD_ID_MISSING" in launcher, "current-thread preflight missing")
    require('lease="$CCO_LEASE_ROOT/$session_uuid"' in launcher, "new leases are not keyed by session identity")
    require("LEASE_CONFLICT" in launcher, "same-session lease check missing")
    require("LEASE_PROCESS_GROUP_CONFLICT" in launcher, "same-session process-group check missing")
    require("LEASE_STATE_AMBIGUOUS" in launcher, "ambiguous lease state is not fail closed")
    require(
        "CLAUDE_RESUME_WORKER_STILL_LIVE" in launcher,
        "resume does not prove the exact session is dead independently of its lease",
    )
    for name, text, marker in (
        ("launcher", launcher, "CLAUDE_RESUME_LIVENESS_UNPROVEN"),
        ("rotate", rotate, "CLAUDE_ROTATE_LIVENESS_UNPROVEN"),
        ("retire", retire, "CLAUDE_RETIRE_LIVENESS_UNPROVEN"),
    ):
        require(marker in text, f"{name} treats unprovable liveness as a dead worker")
    require("PTY_PROCESS_GROUP_ISOLATION_REQUIRED" in launcher, "worker process-group isolation missing")
    require(
        "cco_worker_live_reason" in retire and "cco_worker_live_reason" in rotate,
        "custody paths use different liveness proofs",
    )
    require("cco_thread_root_has_live_worker" in launcher, "same-thread/root live-worker launch gate missing")
    require("CCO_ASSIGNMENT_ROOT" in runtime and "cco_terminalize_assignment" in runtime, "durable assignment state missing")
    assign = read(SKILL / "scripts/assign-worker.zsh")
    require(
        "CODEX_CLAUDE_MAX_BUSY_WORKERS:-2" in launcher
        and "CODEX_CLAUDE_MAX_BUSY_WORKERS:-2" in assign
        and "CLAUDE_LAUNCH_CAPACITY_BUSY" in launcher
        and "CLAUDE_ASSIGN_CAPACITY_BUSY" in assign,
        "shared launch/assignment admission default missing",
    )
    require(
        "--idle" in launcher
        and "idle_unreserved" in launcher
        and launcher.index('cco_create_reservation "$session_uuid" "$root" "$thread_hash"')
        < launcher.index('print -r -- "CODEX_PTY_WORKER_READY $ready_json"'),
        "normal launch does not reserve before READY or lacks explicit idle compatibility",
    )
    require(
        '{version:2,state:"reserved",access:"none"' in runtime
        and "cco_open_assignments" in runtime
        and 'task_id:null' in runtime,
        "access:none reservation schema missing",
    )
    require(
        '.state = "active" | .access = "write"' in assign
        and "own_reservation" in assign,
        "assignment does not atomically upgrade its launch reservation",
    )
    require("CLAUDE_ASSIGN_DUPLICATE_ACTIVE" in assign and "CLAUDE_ASSIGN_ROOT_BUSY" in assign, "assignment conflict handling missing")
    require(
        assign.index('/bin/mv -- "$health_assignment_tmp" "$health_dir/assignment.json"')
        < assign.index('/bin/mv -- "$assignment_tmp" "$assignment_record"'),
        "write assignment is published before stage-health baseline",
    )
    require(
        stage_guard_text.index('write_scalar "$health/max_cache_read_input_tokens"')
        < stage_guard_text.index('write_scalar "$health/transcript_cursor_bytes"'),
        "transcript cursor can advance before cache maximum is durable",
    )
    require("cco_terminalize_assignment" in rotate and "cco_terminalize_assignment" in retire, "lifecycle assignment release missing")
    require(
        os.stat(SKILL / "scripts/reconcile-orphan.zsh").st_mode & stat.S_IXUSR,
        "operator orphan reconciliation is not executable",
    )
    for marker in (
        "CODEX_PTY_ORPHAN_PREVIEW",
        "CODEX_PTY_ORPHAN_RECONCILED",
        "CLAUDE_ORPHAN_WORKER_STILL_LIVE",
        "CLAUDE_ORPHAN_CONFIRMATION_MISMATCH",
        "worktree_preserved:true",
    ):
        require(marker in reconcile, f"operator orphan reconciliation contract missing: {marker}")
    require(
        "cco_terminalize_assignment" in reconcile
        and "--apply" in reconcile
        and "/bin/kill" not in reconcile
        and "rm -rf" not in reconcile,
        "operator orphan reconciliation can signal/delete or lacks two-step terminalization",
    )
    require("Bash(*reconcile-orphan.zsh*)" in launcher, "Claude worker can invoke operator reconciliation")
    require(
        "cco_scope_overlaps" not in runtime,
        "scope-overlap exclusivity helper survives in the runtime library",
    )
    require(
        'comm=' not in launcher and 'name == "claude"' not in launcher,
        "launcher still discovers Claude processes by name",
    )
    require(
        '"$lease" == "$CCO_LEASE_ROOT/$uuid" || "$lease" == "$CCO_LEASE_ROOT/$path_hash"' in runtime,
        "durable leases must accept session keying and the legacy root keying",
    )
    require("cco_session_lease" in runtime, "session lease resolution missing")
    require("--add-missing" in setup and "UNSAFE_COLLISION" in setup, "native additive update safety contract missing")
    require(
        "cco_session_lease" in launcher and "cco_session_lease" in read(SKILL / "scripts/assign-worker.zsh"),
        "launch and assignment do not resolve the same session lease",
    )
    require("cco_lease_has_status_registration" in toggle, "toggle can act outside durable registrations")
    require(
        "busy=$busy_count/2" in toggle
        and "active=$active_count" in toggle
        and "reserved=$reserved_count" in toggle
        and "orphaned=$orphaned_count" in toggle
        and "stale_reserved=$stale_reserved_count" in toggle,
        "shared admission status is missing",
    )
    require('/bin/kill -TERM -- "-$worker_group"' in toggle, "kill switch does not terminate verified groups")
    require("kill -KILL" not in toggle, "kill switch must fail closed instead of force-killing uncertain groups")
    require("codex-pty-worker" in runtime, "durable owner namespace missing")
    require('"$runtime_schema" == "1" || "$runtime_schema" == "2" || "$runtime_schema" == "3" || "$runtime_schema" == "4" || "$runtime_schema" == "5"' in runtime, "durable legacy/current schema support missing")
    require("pgrep" not in toggle and "pkill" not in toggle, "toggle contains a broad process-name matcher")

    live_check = retire.index("CLAUDE_RETIRE_WORKER_STILL_LIVE")
    retirement_write = retire.index("retirement_tmp=$(mktemp")
    require(live_check < retirement_write, "retirement marker can precede live-worker rejection")
    require("cco_lease_is_live" in runtime, "shared liveness proof does not verify lease identity")
    require(
        "ps -axo args=" in runtime
        and '"${argv[$index]}" == "--name"' in runtime
        and '"${argv[$(( index + 1 ))]:-}" == "$uuid"' in runtime,
        "shared liveness fallback lacks one-snapshot exact argv matching",
    )
    expected_native = {
        "source_explorer": ("gpt-5.6-luna", "medium"),
        "scout": ("gpt-5.6-luna", "medium"),
        "test_runner": ("gpt-5.6-luna", "low"),
        "mech_executor": ("gpt-5.6-terra", "medium"),
        "reviewer": ("gpt-5.6-terra", "high"),
        "security_reviewer": ("gpt-5.6-sol", "high"),
    }
    for role, (model, _) in expected_native.items():
        require(f"{role} {model}" in setup, f"native default model drift: {role}")
    require("--role-model" in setup, "native per-role override missing")
    require("CODEX_NATIVE_AGENT_MODEL" in setup, "native uniform environment override missing")
    require("DRY_RUN: no files written" in setup, "native setup must default to dry run")
    require("REFUSING_TO_OVERWRITE" in setup, "native setup overwrite protection missing")
    require("NATIVE_AGENT_SETUP_BUSY" in setup, "native setup destination lock missing")
    require('/bin/ln -- "$tmp" "$destination/$role.toml"' in setup, "native setup lacks atomic no-replace installation")
    for role, (_, effort) in expected_native.items():
        template = SKILL / "assets/native-agents" / f"{role}.toml.in"
        require(template.is_file(), f"native role template missing: {role}")
        template_text = read(template)
        require('model = "@MODEL@"' in template_text, f"native role not configurable: {role}")
        require(f'model_reasoning_effort = "{effort}"' in template_text, f"native reasoning drift: {role}")
        instructions = re.search(r'developer_instructions = """\n(.*?)\n"""', template_text, re.DOTALL)
        require(instructions is not None and instructions.group(1).startswith("Outcome:"), f"native prompt not outcome-first: {role}")
        normalized_instructions = " ".join(instructions.group(1).split())
        if role == "scout":
            for marker in ("Boundaries:", "Done when:", "Choose"):
                require(marker in normalized_instructions, f"native prompt contract missing {marker}: {role}")
            require(len(instructions.group(1).split()) <= 100, f"native prompt is no longer lean: {role}")
        else:
            for marker in ("Boundary:", "Return", "Choose the method."):
                require(marker in normalized_instructions, f"native prompt contract missing {marker}: {role}")
            require(len(instructions.group(1).split()) <= 85, f"native prompt is no longer lean: {role}")

    for marker in (
        '--sandbox "$sandbox_mode"',
        "--ignore-user-config",
        "--disable multi_agent",
        "--disable apps",
        "--disable hooks",
        "approval_policy=\"never\"",
        "web_search=\"disabled\"",
        "mcp_servers={}",
        "NATIVE_ROLE_SANDBOX_MISMATCH",
        "NATIVE_TRUSTED_ROLE_PROFILE_MISSING",
        "NATIVE_ROLE_PROFILE_CONTRACT_MISMATCH",
        "CODEX_NATIVE_ISOLATED_START",
    ):
        require(marker in native_runner, f"isolated native launcher missing: {marker}")
    require(
        'source_explorer|scout|reviewer|security_reviewer)' in native_runner
        and 'required_sandbox="read-only"' in native_runner,
        "read-only native role map drift",
    )
    require(
        'mech_executor|test_runner)' in native_runner
        and 'required_sandbox="workspace-write"' in native_runner,
        "write-capable native role map drift",
    )
    require('task=$(cat)' in native_runner and 'print -rn -- "$task"' in native_runner, "native task is not stdin-only")
    for phrase in (
        "custom-agent `sandbox_mode` is a role default",
        "run-native-agent.zsh source_explorer",
        "Never run this isolated path",
        "repository-owned\nprofile is not a trusted isolation authority",
    ):
        require(phrase in skill_text, f"native sandbox contract missing: {phrase}")

    normalized_policy = " ".join(policy.split())
    for phrase in (
        "Codex owns user intent",
        "minimizes end-to-end model cost and elapsed time",
        "one edit-capable owner",
        "permanently local-only",
        "These restrictions bind the worker, not the owning Codex session",
        "already authorized by the active goal",
        "material scope expansion",
        "Fallback transfers ownership",
        "pass the exact custom profile through `agent_type`",
        "renaming `task_name` is not a routing fallback",
        "parent runtime is broader than the role",
        "never a repository-owned",
    ):
        require(phrase in normalized_policy, f"opt-in policy missing: {phrase}")
    require(
        "exact current-user authorization" not in normalized_policy,
        "opt-in policy restored the obsolete duplicate-confirmation gate",
    )

    text_files: list[Path] = []
    for path in ROOT.rglob("*"):
        if ".git" in path.parts or not path.is_file():
            continue
        try:
            path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        text_files.append(path)
    corpus = "\n".join(read(path) for path in text_files)
    forbidden = {
        "/" + "Users" + "/": "hardcoded macOS home path",
        "sk-" + "ant-": "Anthropic credential prefix",
        "sk-" + "proj-": "OpenAI credential prefix",
        "AK" + "IA": "AWS credential prefix",
    }
    corpus_casefold = corpus.casefold()
    for needle, label in forbidden.items():
        require(needle.casefold() not in corpus_casefold, f"{label} found in repository")
    implementation_corpus = "\n".join(
        read(path) for path in text_files if path != ROOT / "README.md"
    ).casefold()
    removed_name = "code" + "indexer"
    removed_spaced_name = "code" + " " + "indexer"
    require(
        removed_name not in implementation_corpus
        and removed_spaced_name not in implementation_corpus,
        "removed semantic-index integration found outside the branch description",
    )
    require(
        re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", corpus, re.I) is None,
        "concrete session UUID found",
    )
    anthropic_key = "ANTHROPIC" + "_API_KEY="
    openai_key = "OPENAI" + "_API_KEY="
    require(anthropic_key not in corpus and openai_key not in corpus, "credential assignment found")

    for script in (SKILL / "scripts").glob("*.zsh"):
        mode = stat.S_IMODE(script.stat().st_mode)
        require(mode & stat.S_IXUSR, f"script is not executable: {script.relative_to(ROOT)}")

    print("static invariants: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"static invariants: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
