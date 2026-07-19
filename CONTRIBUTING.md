# Contributing

Contributions are welcome, especially portability fixes, adversarial tests for
lease/custody behavior, and documentation corrections tied to official product
documentation.

## Development

1. Fork and clone the repository.
2. Keep changes credential-free and machine-independent.
3. Run `./scripts/self-check.zsh`.
4. Explain the authority, custody, and recovery impact of runtime changes in
   the pull request.

Do not commit runtime registrations, leases, transcripts, prompts containing
private task data, generated Claude settings, credentials, or user-specific
paths. Tests must not require Claude, Codex, API keys, or network access.

Runtime changes should preserve these invariants:

- one edit-capable owner per canonical worktree;
- a worker is registered to the current Codex thread before it is resumable;
- native fallback never overlaps a live Claude writer;
- retirement permanently blocks that assignment from Claude resume;
- the kill-switch marker is the only enabled/disabled state;
- schema-2 workers snapshot the exact session-scoped agent roster and clear any
  inherited global Claude subagent-model override;
- schema-2 routing rejects unlisted roles and mismatched per-invocation model
  overrides before the Agent tool runs;
- the published per-role model and reasoning map changes only with tests and
  documentation in the same pull request;
- standalone Claude sessions and user configuration remain outside scope.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
