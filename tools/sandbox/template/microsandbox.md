# Microsandbox

- You run inside a microsandbox (`msb`) microVM as user `agent` with permissions bypassed; the host is the developer's
  machine. Only the mounted directories persist on the host; everything else is lost when the sandbox is removed.
- Mounted at their host paths: this checkout (read-write) and the main checkout's `.git` when this is a git worktree
  (read-write).
- Read-only on purpose, because the host runs them: `tools/sandbox/`, `justfile`, the git hooks, `.git/config`,
  `.claude/settings.json` and `.claude/settings.local.json`. Ask the developer to change those.
- Git commands that write `.git/config` fail: push with `git push origin <branch>`, never `git push -u`, and don't add
  remotes or set upstreams. Git over SSH uses the developer's SSH agent on the host.
- Never run `git worktree prune` or remove worktrees: the developer's other worktrees aren't mounted, so git calls them
  prunable, and pruning deletes their records on the host.
- Network access is limited to an allowlist (Anthropic, GitHub, the npm registry); a blocked host means asking the
  developer to add it to `tools/sandbox/allowed-hosts.txt`.
- Available: Node.js and npm (version from `.tool-versions`), just, gh, git, jq, rtk. There is no Docker.
- The app runs with `npm start` on port 5000 inside the sandbox; test it with `curl http://localhost:5000`.
- Credentials in the environment (`GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`) are placeholders; the sandbox proxy swaps in
  the real value on the way out. Never run `gh auth login`.
- `node_modules` is shared with the host; install with `npm ci`, not with packages that need native builds for Linux.
- Startup logs: `/tmp/hatjitsu-startup.log`, `/tmp/claude-update.log` and `/tmp/ssh-agent-bridge.log`.
