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
    require(manifest["version"].startswith("0.3.2+codex."), "local cachebuster version drift")
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
        "Codex owns the repository trust",
        "decision and does not ask the user",
        "This does not expand any other authority",
    ):
        require(marker in skill_text, f"Codex-owned repository trust policy missing: {marker}")

    launcher = read(SKILL / "scripts/launch-worker.zsh")
    runtime = read(SKILL / "scripts/runtime-lib.zsh")
    rotate = read(SKILL / "scripts/rotate-worker.zsh")
    retire = read(SKILL / "scripts/retire-native-fallback.zsh")
    toggle = read(SKILL / "scripts/toggle-agents.zsh")
    setup = read(SKILL / "scripts/setup-native-agents.zsh")
    native_runner = read(SKILL / "scripts/run-native-agent.zsh")
    policy = read(SKILL / "references/codex-policy-snippet.md")
    agent_roster = json.loads(read(SKILL / "assets/worker-agents.json"))

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
    expected_agent_efforts = {
        "explorer": None,
        "log-analyzer": None,
        "test-triager": None,
        "implementer": "high",
        "debugger": "xhigh",
        "reviewer": "high",
        "security-reviewer": "xhigh",
        "long-horizon": "xhigh",
    }
    expected_agent_tools = {
        "explorer": ["Read", "Grep", "Glob", "Bash"],
        "log-analyzer": ["Read", "Grep", "Glob", "Bash"],
        "test-triager": ["Read", "Grep", "Glob", "Bash"],
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
        "explorer", "log-analyzer", "test-triager", "debugger", "reviewer", "security-reviewer"
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

    worker_prompt = read(SKILL / "assets/worker-system-prompt.txt")
    require(worker_prompt.startswith("Outcome:"), "worker prompt is not outcome-first")
    for heading in ("Authority:", "Boundaries:", "Roster:", "Handoff:"):
        require(heading in worker_prompt, f"worker prompt contract missing {heading}")
    require("choose the method" in worker_prompt.casefold(), "worker prompt does not grant method choice")
    require("launcher enforces their roles and models" in worker_prompt, "runtime routing boundary missing")
    require("CodeIndexer is optional" in worker_prompt and "verify material indexed findings in source" in worker_prompt, "lean CodeIndexer contract missing")
    require(len(worker_prompt.split()) <= 240, "worker prompt is no longer lean")

    hook_text = read(SKILL / "scripts/worker-subagent-contract.zsh")
    router_text = read(SKILL / "scripts/worker-agent-router.zsh")
    hook_context = re.search(r"context='([^']+)'", hook_text)
    require(hook_context is not None, "subagent hook context missing")
    require("choose the method" in hook_context.group(1).casefold(), "subagent hook prescribes method")
    require(len(hook_context.group(1).split()) <= 100, "subagent hook context is no longer lean")
    for role, model in expected_agent_models.items():
        require(role in router_text and model in router_text, f"router mapping missing: {role}")
    require('"permissionDecision":"deny"' in router_text, "router lacks a blocking decision")
    require("subagent_type" in router_text, "router does not inspect the requested role")

    require("CODEX_CLAUDE_PARENT_MODEL:-opus" in launcher, "Opus parent default missing")
    require('parent_effort="max"' in launcher, "maximum Claude parent effort missing")
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
    require('--mcp-config "$runtime_mcp"' in launcher, "pinned CodeIndexer MCP snapshot is not injected")
    require('mcp_args=(--mcp-config "$runtime_mcp")' in launcher, "MCP snapshot is not schema-scoped")

    require("runtime_schema_version" in launcher and 'print -r -- "4"' in launcher, "runtime schema-4 pin missing")
    require('print -r -- "0.3.1" > "$registration/runtime_version"' in launcher, "runtime schema-4 version drift")
    for snapshot in (
        "worker-agents.json",
        "worker-system-prompt.txt",
        "worker-subagent-contract.zsh",
        "worker-agent-router.zsh",
        "worker-compaction-counter.zsh",
        "worker-codeindexer-guard.zsh",
        "codeindexer-mcp.json",
        "worker-settings.json",
    ):
        require(f'runtime/{snapshot}' in launcher or f'runtime_dir/{snapshot}' in launcher or snapshot in launcher, f"snapshot missing: {snapshot}")
    require('--append-system-prompt-file "$runtime_prompt"' in launcher, "live worker does not use prompt snapshot")
    require("$runtime_hook" in launcher, "generated settings do not pin hook snapshot")
    require("$runtime_agent_router" in launcher, "generated settings do not pin router snapshot")
    require("$runtime_compaction_counter" in launcher, "generated settings do not pin PostCompact observer")
    require("$runtime_codeindexer_guard" in launcher, "generated settings do not pin CodeIndexer guard")
    require("PostCompact" in launcher, "completed compactions are not observed")
    require("/bin/chmod 700 \"$runtime_dir\"" in launcher, "runtime directory mode missing")
    require("/bin/chmod 600 \"$runtime_prompt\"" in launcher, "prompt snapshot mode missing")

    require("CLAUDE_RESUME_RETIRED" in launcher, "retired resume rejection missing")
    require("CLAUDE_RESUME_OWNERSHIP_UNPROVEN" in launcher, "thread/root resume validation missing")
    require("CODEX_THREAD_ID_MISSING" in launcher, "current-thread preflight missing")
    require('lease="$CCO_LEASE_ROOT/$session_uuid"' in launcher, "lease is not keyed by the session UUID")
    require("CLAUDE_RESUME_WORKER_STILL_LIVE" in launcher, "duplicate resume of a live session is not rejected")
    require("PTY_PROCESS_GROUP_ISOLATION_REQUIRED" in launcher, "worker process-group isolation missing")
    require(
        "cco_scope_overlaps" not in launcher and "cco_scope_overlaps" not in runtime,
        "root-overlap exclusivity survived the ownership model",
    )
    require(
        "CLAUDE_CWD_CONFLICT" not in launcher and "comm=" not in launcher,
        "launcher still discovers foreign Claude processes by name or cwd",
    )
    require(
        "cco_worker_live_reason" in retire and "cco_worker_live_reason" in rotate,
        "custody paths use different liveness proofs",
    )
    require(
        all('cco_worker_live_reason "$session_uuid"' in script for script in (retire, rotate)),
        "custody liveness proof is not scoped to the named session UUID",
    )
    require("cco_lease_has_durable_registration" in toggle, "toggle can act outside durable registrations")
    require('/bin/kill -TERM -- "-$worker_group"' in toggle, "kill switch does not terminate verified groups")
    require("kill -KILL" not in toggle, "kill switch must fail closed instead of force-killing uncertain groups")
    require("codex-pty-worker" in runtime, "durable owner namespace missing")
    require('"$runtime_schema" == "1" || "$runtime_schema" == "2" || "$runtime_schema" == "3" || "$runtime_schema" == "4"' in runtime, "durable legacy/current schema support missing")
    require("pgrep" not in toggle and "pkill" not in toggle, "toggle contains a broad process-name matcher")

    live_check = retire.index("CLAUDE_RETIRE_WORKER_STILL_LIVE")
    retirement_write = retire.index("retirement_tmp=$(mktemp")
    require(live_check < retirement_write, "retirement marker can precede live-worker rejection")
    require("cco_lease_is_live" in runtime, "shared liveness proof does not verify lease identity")
    require("ps -axo pid=" in runtime, "shared liveness proof lacks missing/stale-lease process scan")
    expected_native = {
        "source_explorer": ("gpt-5.6-luna", "medium"),
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
        "NATIVE_ROLE_SANDBOX_MISMATCH",
        "NATIVE_TRUSTED_ROLE_PROFILE_MISSING",
        "NATIVE_ROLE_PROFILE_CONTRACT_MISMATCH",
        "CODEX_NATIVE_ISOLATED_START",
        "cco_codeindexer_mcp_json",
        "enabled_tools=$readonly_codeindexer_tools",
        "disabled_tools=$denied_codeindexer_tools",
        "default_tools_approval_mode",
        "required=true",
        "task supplies the exact indexed project name",
    ):
        require(marker in native_runner, f"isolated native launcher missing: {marker}")
    require(
        'source_explorer|reviewer|security_reviewer)' in native_runner
        and 'required_sandbox="read-only"' in native_runner,
        "read-only native role map drift",
    )
    require(
        'mech_executor|test_runner)' in native_runner
        and 'required_sandbox="workspace-write"' in native_runner,
        "write-capable native role map drift",
    )
    for tool in (
        "search_code",
        "read_chunk",
        "read_file_range",
        "file_deps",
        "find_callers",
        "find_callees",
        "find_references",
        "find_test_coverage",
    ):
        require(f'"{tool}"' in native_runner, f"native CodeIndexer read tool missing: {tool}")
    for mixed_action_tool in ('"projects"', '"solutions"', '"skills"', '"memory_cards"'):
        require(mixed_action_tool in native_runner, f"mixed-action native CodeIndexer deny missing: {mixed_action_tool}")
    require('task=$(cat)' in native_runner and 'print -rn -- "$task"' in native_runner, "native task is not stdin-only")

    native_routing_contract = (
        "`task_name` is only a semantic instance identifier",
        "mandatory `agent_type` field",
        "field is `subagent_type`; do not substitute it for native routing",
        "`fork_turns=all` and its default are incompatible with",
        "non-empty `agent_role` exactly equal to the requested `agent_type`",
        "means stop the child: no task assignment and no edit custody transfer",
        "sandbox inheritance is a separate runtime",
        "not corrected by configuration",
        "custom-agent `sandbox_mode` is a role default",
        "run-native-agent.zsh source_explorer",
        "Never run this isolated path and a built-in child",
        "mixed-action management tools are not exposed",
        "repository-owned\nprofile is not a trusted isolation authority",
        "exact registered CodeIndexer project name",
        "explicit deny-list",
    )
    for phrase in native_routing_contract:
        require(phrase in skill_text, f"native routing contract missing: {phrase}")

    readme = read(ROOT / "README.md")
    for phrase in (
        "`agent_type` selects the installed custom profile",
        "Missing or mismatched `agent_role` fails closed",
        "`fork_turns=all` and the default are invalid",
        "`subagent_type` field for native routing",
        "pure read/search MCP tools",
    ):
        require(phrase in readme, f"native routing documentation missing: {phrase}")

    for phrase in (
        "Codex owns user intent",
        "minimizes end-to-end model cost and elapsed time",
        "ownership, not exclusivity",
        "non-overlapping edit scope",
        "belonging to another Codex thread",
        "permanently local-only",
        "exact current-user authorization",
        "Fallback transfers ownership",
        "pass the exact custom profile through `agent_type`",
        "renaming `task_name` is not a routing fallback",
        "parent runtime is broader than the role",
        "never a repository-owned",
    ):
        require(phrase in policy, f"opt-in policy missing: {phrase}")

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
