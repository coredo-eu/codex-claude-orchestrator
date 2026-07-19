# Security policy

## Supported versions

Security fixes target the latest release. This project is pre-1.0; review each
upgrade before installing it.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/coredo-eu/codex-claude-orchestrator/security/advisories/new).
Do not open a public issue containing credentials, private transcripts,
personal data, machine-specific paths, or exploit details.

If that channel is unavailable, keep the report private and contact the
maintainer through the identity shown on the GitHub repository.

Include the affected version, impact, minimal reproduction, and any suggested
mitigation. Never include live tokens or full Claude/Codex session state.

## Security boundaries

The launcher is policy enforcement and identity checking, not an operating
system sandbox. Claude Code, Codex, the shell, installed hooks, project
instructions, MCP servers, and the target repository remain part of the trusted
computing base. See the threat model in `README.md` before use.
