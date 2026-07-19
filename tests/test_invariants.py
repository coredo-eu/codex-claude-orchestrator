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
    require(re.fullmatch(r"\d+\.\d+\.\d+", manifest["version"]) is not None, "strict semver required")
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

    launcher = read(SKILL / "scripts/launch-worker.zsh")
    runtime = read(SKILL / "scripts/runtime-lib.zsh")
    retire = read(SKILL / "scripts/retire-native-fallback.zsh")
    toggle = read(SKILL / "scripts/toggle-agents.zsh")
    setup = read(SKILL / "scripts/setup-native-agents.zsh")
    policy = read(SKILL / "references/codex-policy-snippet.md")

    require("CODEX_CLAUDE_PARENT_MODEL:-opus" in launcher, "Opus parent default missing")
    require("CODEX_CLAUDE_SUBAGENT_MODEL:-haiku" in launcher, "Haiku subagent default missing")
    require('CLAUDE_CODE_SUBAGENT_MODEL="$subagent_model"' in launcher, "subagent environment override missing")
    require('--model "$parent_model"' in launcher, "parent model CLI pin missing")
    require('--setting-sources ""' in launcher, "isolated setting sources missing")
    require("--strict-mcp-config" in launcher, "external MCP configurations are not excluded")
    require("--mcp-config" not in launcher, "launcher must not inject an MCP configuration")

    require("runtime_schema_version" in launcher and 'print -r -- "1"' in launcher, "runtime schema pin missing")
    for snapshot in (
        "worker-system-prompt.txt",
        "worker-subagent-contract.zsh",
        "worker-settings.json",
    ):
        require(f'runtime/{snapshot}' in launcher or f'runtime_dir/{snapshot}' in launcher or snapshot in launcher, f"snapshot missing: {snapshot}")
    require('--append-system-prompt-file "$runtime_prompt"' in launcher, "live worker does not use prompt snapshot")
    require("$runtime_hook" in launcher, "generated settings do not pin hook snapshot")
    require("/bin/chmod 700 \"$runtime_dir\"" in launcher, "runtime directory mode missing")
    require("/bin/chmod 600 \"$runtime_prompt\"" in launcher, "prompt snapshot mode missing")

    require("CLAUDE_RESUME_RETIRED" in launcher, "retired resume rejection missing")
    require("CLAUDE_RESUME_OWNERSHIP_UNPROVEN" in launcher, "thread/root resume validation missing")
    require("CODEX_THREAD_ID_MISSING" in launcher, "current-thread preflight missing")
    require("LEASE_SCOPE_CONFLICT" in launcher and "LEASE_CONFLICT" in launcher, "single-writer lease checks missing")
    require("PTY_PROCESS_GROUP_ISOLATION_REQUIRED" in launcher, "worker process-group isolation missing")
    require("REGISTRATION_PROCESS_GROUP_CONFLICT" in launcher, "orphan process-group launch check missing")
    require("cco_process_group_has_live_members" in retire, "retirement lacks descendant process-group check")
    require("cco_lease_has_durable_registration" in toggle, "toggle can act outside durable registrations")
    require('/bin/kill -TERM -- "-$worker_group"' in toggle, "kill switch does not terminate verified groups")
    require("kill -KILL" not in toggle, "kill switch must fail closed instead of force-killing uncertain groups")
    require("codex-pty-worker" in runtime, "durable owner namespace missing")
    require("pgrep" not in toggle and "pkill" not in toggle, "toggle contains a broad process-name matcher")

    live_check = retire.index("CLAUDE_RETIRE_WORKER_STILL_LIVE")
    retirement_write = retire.index("retirement_tmp=$(mktemp")
    require(live_check < retirement_write, "retirement marker can precede live-worker rejection")
    require("cco_lease_is_live" in retire, "retirement does not verify lease identity")
    require("ps -axo pid=" in retire, "retirement lacks missing/stale-lease process scan")

    require("CODEX_NATIVE_AGENT_MODEL:-gpt-5.4-mini" in setup, "documented cheap Codex default missing")
    require("DRY_RUN: no files written" in setup, "native setup must default to dry run")
    require("REFUSING_TO_OVERWRITE" in setup, "native setup overwrite protection missing")
    require("NATIVE_AGENT_SETUP_BUSY" in setup, "native setup destination lock missing")
    require('/bin/ln -- "$tmp" "$destination/$role.toml"' in setup, "native setup lacks atomic no-replace installation")
    for role in ("source_explorer", "mech_executor", "reviewer", "security_reviewer", "test_runner"):
        template = SKILL / "assets/native-agents" / f"{role}.toml.in"
        require(template.is_file(), f"native role template missing: {role}")
        require('model = "@MODEL@"' in read(template), f"native role not configurable: {role}")

    for phrase in (
        "Codex owns user intent",
        "minimizes end-to-end model cost and elapsed time",
        "one edit-capable owner",
        "permanently local-only",
        "exact current-user authorization",
        "Fallback transfers ownership",
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
