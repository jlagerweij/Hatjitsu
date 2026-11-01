# Claude Code in a microsandbox

Runs Claude Code with permissions bypassed in a [microsandbox](https://microsandbox.dev) (`msb`): a microVM that can't
touch the rest of your machine. Every checkout or worktree gets its own sandbox. macOS only.

## First time

1. Install `msb` (0.7 or later, `brew install microsandbox`), `jq`, `just` and a container runtime (Colima, Rancher
   Desktop or Docker Desktop; it only builds the sandbox image). Log in with `gh auth login` and have your SSH key in
   your SSH agent (`ssh-add -l`).
2. Run `just sandbox-setup`. It runs `claude setup-token` (a browser opens to log in) and stores the long-lived token
   in your macOS Keychain. Credentials stay on your machine: at every start, `sandbox.sh` hands msb the Claude token
   and your `gh auth token`, and the sandbox only sees placeholders that msb's proxy swaps for the real value on the
   way to Anthropic or GitHub.

   Git push and pull work over SSH: your host's SSH agent is exposed to the sandbox over vsock, so the agent can use
   your keys (not read them) while a sandbox runs. The GitHub token is only for `gh` (PRs, CI status) and has the
   scopes of your `gh` login. Don't run `gh auth login` inside a sandbox: the token then sits in the sandbox, readable
   by the agent.
3. Run `just sandbox-doctor`.

## Daily use

```sh
just sandbox-new feature/short-name          # worktree + branch from origin/master, then Claude in its sandbox
just sandbox                                 # Claude in this checkout's sandbox; extra args go to claude
just sandbox-rm                              # remove this checkout's sandbox (your files stay)
just sandbox-rm-worktree feature/short-name  # remove its sandbox and clean worktree; the branch stays
just sandbox-prune                           # remove the sandboxes of deleted checkouts
```

Prefer `just sandbox-new`: in your main checkout, a branch Claude switches to switches your checkout too. New
worktrees go next to the main checkout (override with `HATJITSU_SANDBOX_WORKTREE_ROOT`), branch from `origin/master`
(override with `HATJITSU_SANDBOX_BASE`) and get `npm ci` on the host.

A sandbox has your checkout and keeps its own state (Claude's history, `/tmp`) across restarts; it's lost when the
sandbox is removed. The first `just sandbox` builds the image (`hatjitsu-sandbox:<hash>`) with Docker and loads it into
msb. When `tools/sandbox/` or `.tool-versions` changes, `just sandbox` tells you to recreate it with `just sandbox-rm`.

`just sandbox-doctor` lists what it checks. `msb ls` shows all sandboxes; `msb exec -u agent <name>` opens a
shell in one.

## What the agent can still affect

Read-only in the sandbox: this folder, the `justfile`, the git hooks, `.git/config` and `.claude/settings*.json`. Git
commands that write `.git/config` (`git push -u`, `git remote add`) fail in the sandbox. The rest of your checkout and
its `.git` is writable, so review it like a pull request before you run it on the host:

- code and `package.json` scripts, and `node_modules` (shared with the host);
- branches the agent created or moved, and what it pushed.

Outside your checkout, the agent acts as you with the credentials the sandbox passes on:

- GitHub: anything your `gh` token's scopes allow, and git over SSH with any key in your SSH agent;
- Anthropic: your Claude subscription, through the token from `just sandbox-setup`.

## Network

A sandbox only reaches the hosts in `ALLOWED_HOSTS` in `sandbox.sh` (Anthropic, GitHub, the npm registry) on port 443,
plus `github.com` on port 22; everything else is blocked. SSH has no hostname to inspect, so the sandbox runs with
`--net-strict=false`: hostname rules are matched on the IPs DNS returns. A host added to the list reaches a sandbox
when it's recreated.

## Tool versions

Node.js comes from the repo's `.tool-versions` (the `node:<version>-trixie-slim` image). just, gh and rtk are pinned
with checksums in `template/Dockerfile`; Claude Code installs its latest version and updates itself at every start.

## Troubleshooting

- **Claude asks to log in, or gets a 401:** the token expired or was revoked; run `just sandbox-setup` and replace it.
- **`gh` in the sandbox gets a 401:** check `gh auth status` on the host; the token is read at every start, so restart
  the sandbox (`msb stop <name>`, then `just sandbox`).
- **git over SSH fails:** check `ssh-add -l` on the host, then `just sandbox` again (it restarts the bridge).
- **A blocked host:** add it to `ALLOWED_HOSTS` in `sandbox.sh`, then `just sandbox-rm` and `just sandbox`.
- **Startup logs in the sandbox:** `/tmp/hatjitsu-startup.log`, `/tmp/claude-update.log`,
  `/tmp/ssh-agent-bridge.log`.
