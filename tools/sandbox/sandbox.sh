#!/usr/bin/env bash
# Claude Code in a microsandbox (msb) for a Hatjitsu checkout. Called by the `just sandbox*` recipes;
# see tools/sandbox/README.md.
#
#   sandbox.sh run [claude args...]          create this checkout's sandbox if needed, then attach
#   sandbox.sh new BRANCH [claude args...]   create or reuse a worktree for BRANCH, then run its sandbox
#   sandbox.sh setup                         one-time: store a Claude token in the macOS Keychain
#   sandbox.sh rm                            remove this checkout's sandbox
#   sandbox.sh rm-worktree BRANCH            remove BRANCH's sandbox and worktree; the branch stays
#   sandbox.sh prune                         remove sandboxes whose checkout no longer exists
#   sandbox.sh doctor                        check the prerequisites
#
# What `run` does:
#   1. Pass on the credentials: the Claude token (Keychain) and `gh auth token` go into this process's environment,
#      where msb reads them at every start. The sandbox only sees placeholders.
#   2. Build the image if it's missing: template/Dockerfile → docker build → msb load.
#   3. Create the sandbox if it doesn't exist (mounts, network allowlist, secrets, SSH agent), else start it.
#   4. Run template/startup.sh in it (SSH agent bridge, Claude update), then attach Claude to the checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
# msb doesn't record a sandbox's workspace, so we keep it per sandbox here, next to the SSH agent link.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hatjitsu-sandbox"
# macOS gives SSH_AUTH_SOCK a new path at every login, but msb keeps the path a sandbox was created with.
SSH_LINK="$CACHE_DIR/ssh-agent.sock"
SSH_VSOCK_PORT=2222   # startup.sh bridges this vsock port to /tmp/ssh-agent.sock in the sandbox
KEYCHAIN_SERVICE=hatjitsu-sandbox-claude

# ====================
# Commands
# ====================

cmd_run() {
  need_msb
  export_credentials
  if sandbox_exists; then
    warn_if_stale
    sandbox_running || msb start -q "$name"
  else
    create_sandbox
  fi
  msb exec --no-tty -u agent "$name" -- /usr/local/libexec/hatjitsu/startup.sh \
    || echo "! Startup steps failed; see /tmp/hatjitsu-startup.log in the sandbox."
  exec msb exec -t -u agent -w "$ws" "$name" -- claude --dangerously-skip-permissions "$@"
}

# The sandbox is set up by this launcher, not the branch's own copy, which the agent may have changed.
cmd_new() {
  local branch="${1:-}" path
  [ -n "$branch" ] || die "Usage: just sandbox-new <branch> [claude args...], e.g. just sandbox-new feature/short-name"
  shift
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "'$branch' is not a valid branch name."
  path="$(worktree_of "$branch")"
  if [ -n "$path" ]; then
    echo "$branch is already checked out in $path; using that."
  else
    path="${HATJITSU_SANDBOX_WORKTREE_ROOT:-$(dirname "$main")}/$branch"
    add_worktree "$branch" "$path"
  fi
  set_workspace "$(git -C "$path" rev-parse --show-toplevel)"
  cmd_run "$@"
}

cmd_setup() {
  need security "Storing the Claude token needs the macOS Keychain."
  need claude "Install Claude Code on the host first."
  local replace=y token
  [ -z "$(claude_token)" ] || read -rp "Claude: a token is already stored. Replace it? [y/N] " replace
  if [ "$replace" = y ] || [ "$replace" = Y ]; then
    echo "Claude: creating a long-lived token for the sandbox; log in in the browser window that opens."
    claude setup-token
    read -rsp "Paste the token it printed (sk-ant-oat…): " token
    echo
    [ -n "$token" ] || die "No token given."
    security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$token"
    echo "✓ Claude token stored in the Keychain ($KEYCHAIN_SERVICE)"
  else
    echo "✓ Claude token kept"
  fi
  if gh auth token >/dev/null 2>&1; then
    echo "✓ GitHub: your gh login is passed on at every start"
  else
    echo "! No gh login on this machine, so Claude can't use gh (PRs, CI status) in the sandbox. Run 'gh auth login'."
  fi
}

cmd_rm() {
  need_msb
  if sandbox_exists; then
    msb rm -f -q "$name"
    echo "✓ Removed sandbox $name"
  else
    echo "No sandbox named $name."
  fi
  rm -f "$(cache_file "$name")"
}

# Checks for changes first, so a dirty worktree doesn't lose its sandbox and then fail to be removed.
cmd_rm_worktree() {
  local branch="${1:-}" path
  [ -n "$branch" ] || die "Usage: just sandbox-rm-worktree <branch>, e.g. just sandbox-rm-worktree feature/short-name"
  path="$(worktree_of "$branch")"
  [ -n "$path" ] || die "$branch isn't checked out in a worktree."
  [ "$path" != "$main" ] || die "$branch is checked out in the main checkout, which stays; to remove its sandbox: just sandbox-rm"
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "$path has uncommitted or untracked changes; commit or discard them first (git -C $path status)."
  set_workspace "$path"
  cmd_rm
  git -C "$main" worktree remove "$path"
  # sandbox-new nests worktrees by branch prefix, e.g. feature/; drop that folder once it's empty.
  rmdir "$(dirname "$path")" 2>/dev/null || true
  echo "✓ Removed $path; branch $branch is kept."
}

cmd_prune() {
  need_msb
  local gone n answer
  gone="$(our_sandboxes | while read -r n; do [ -d "$(cache_field "$n" ws)" ] || echo "$n"; done)"
  [ -n "$gone" ] || { echo "No sandboxes for removed checkouts."; return 0; }
  echo "Sandboxes whose checkout no longer exists:"
  printf '  %s\n' $gone
  read -rp "Remove them? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing removed."; return 0; }
  for n in $gone; do msb rm -f -q "$n" && rm -f "$(cache_file "$n")"; done
}

cmd_doctor() {
  local ok=1
  check "macOS host (the Claude token lives in the Keychain)" "only macOS is supported" test "$(uname -s)" = Darwin
  check "msb installed" "brew install microsandbox" command -v msb
  check "msb host setup" "run: msb doctor" msb doctor
  check "jq installed" "brew install jq" command -v jq
  check "docker reachable (builds the image)" "start your container runtime (e.g. colima start)" docker info
  check "Claude token" "run: just sandbox-setup" test -n "$(claude_token)"
  optional "SSH agent with keys" "git over SSH won't work in the sandbox; ssh-add your key" ssh-add -l
  optional "gh login" "Claude can't use gh in the sandbox; run gh auth login" gh auth token
  image_exists || echo "  image $(image_tag): built by the next just sandbox"
  echo "  this checkout: $name ($(sandbox_exists && sandbox_field "$name" .status || echo "not created yet"))"
  [ "$ok" = 1 ]
}

# ====================
# Creating a sandbox
# ====================

create_sandbox() {
  image_exists || build_image
  msb create -q -n "$name" -m 4G -c 4 -u agent -w "$ws" -H "$name" \
    -e HATJITSU_SANDBOX=1 -e TZ=Europe/Amsterdam -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock \
    "${mount_args[@]}" "${network_args[@]}" "${secret_args[@]}" \
    --vsock "$SSH_LINK:$SSH_VSOCK_PORT" \
    "$(image_tag)" || die "Creating sandbox $name failed. Run 'just sandbox-doctor'."
  printf 'ws=%s\nconfig=%s\n' "$ws" "$(config_hash)" > "$(cache_file "$name")"
}

# The checkout read-write at its host path, so git worktree paths resolve. Read-only what the host runs: this folder,
# the justfile, the git hooks, .git/config (it can name commands git runs) and Claude's project settings.
set_mount_args() {
  local path
  mount_args=(-v "$ws:$ws")
  # A worktree's git metadata lives in the main checkout's .git.
  case "$git_common" in "$ws"/*) ;; *) mount_args+=(-v "$git_common:$git_common") ;; esac
  for path in "$ws/tools/sandbox" "$git_common/hooks"; do
    [ -d "$path" ] && mount_args+=(-v "$path:$path:ro")
  done
  for path in "$ws/justfile" "$git_common/config" "$ws/.claude/settings.json" "$ws/.claude/settings.local.json"; do
    [ -f "$path" ] && mount_args+=(--mount-file "$path:$path:ro")
  done
  true
}

# Deny by default, allow allowed-hosts.txt on 443 and github.com on 22. SSH has no hostname to inspect, so hostname
# rules are matched on the IPs DNS returns (--net-strict=false).
set_network_args() {
  local host rules="allow@dns,allow@github.com:tcp:22"
  while read -r host; do rules+=",allow@$host:tcp:443"; done < <(grep -Ev '^[[:space:]]*(#|$)' "$HERE/allowed-hosts.txt")
  network_args=(--no-net --net-rule "$rules" --net-strict=false)
}

# msb reads the values from this process's environment (export_credentials) and only substitutes them in requests
# to the listed hosts.
set_secret_args() {
  secret_args=(--secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com,claude.ai")
  [ -z "$GH_TOKEN" ] || secret_args+=(--secret "GH_TOKEN@github.com,api.github.com")
}

export_credentials() {
  CLAUDE_CODE_OAUTH_TOKEN="$(claude_token)"
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || die "No Claude token stored; run: just sandbox-setup"
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  export CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN
  if [ -S "${SSH_AUTH_SOCK:-}" ]; then
    ln -sfn "$SSH_AUTH_SOCK" "$SSH_LINK"
  else
    echo "! No SSH agent on the host (SSH_AUTH_SOCK): git over SSH won't work in the sandbox."
  fi
  set_mount_args
  set_network_args
  set_secret_args
}

claude_token() { security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true; }

warn_if_stale() {
  [ "$(cache_field "$name" config)" = "$(config_hash)" ] && return 0
  echo "! $name was created from an older tools/sandbox or .tool-versions. To update it: just sandbox-rm, then"
  echo "  just sandbox. Starting the existing sandbox for now."
}

# ====================
# The image
# ====================

# Tagged with a hash of what it's built from, so a changed Dockerfile or Node version gets a new image.
image_tag() { echo "hatjitsu-sandbox:$(cd "$REPO" && tree_hash tools/sandbox/template .tool-versions)"; }
image_exists() { msb image ls --format json 2>/dev/null | jq -e --arg t "$(image_tag)" '.[] | select(.reference == $t)' >/dev/null; }

build_image() {
  need docker "Install a container runtime (Colima, Rancher Desktop or Docker Desktop)."
  local tag tar node
  tag="$(image_tag)"
  node="$(awk '$1 == "nodejs" { print $2 }' "$REPO/.tool-versions")"
  [ -n "$node" ] || die "No nodejs version in $REPO/.tool-versions."
  echo "Building image $tag (Node $node)..."
  tar="$(mktemp)"
  docker build --pull --build-arg NODE_VERSION="$node" -t "$tag" "$HERE/template" \
    && docker image save "$tag" -o "$tar" \
    && msb load -q -i "$tar" -t "$tag" \
    || { rm -f "$tar"; die "Building image $tag failed."; }
  rm -f "$tar"
  echo "✓ Image $tag loaded."
}

# ====================
# Workspaces and sandbox names
# ====================

# Sets ws (the checkout), git_common (its .git, shared by worktrees), main (the main checkout) and name (the sandbox):
# hatjitsu-<folder>, lowercase [a-z0-9-], at most 63 chars, with a hash suffix if another checkout has that name.
set_workspace() {
  ws="$1"
  git_common="$(git -C "$ws" rev-parse --path-format=absolute --git-common-dir)"
  main="$(dirname "$git_common")"
  name="$(trim_name "hatjitsu-$(basename "$ws" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')" 63)"
  local owner
  owner="$(cache_field "$name" ws)"
  if [ -n "$owner" ] && [ "$owner" != "$ws" ]; then
    name="$(trim_name "$name" 56)-$(printf '%s' "$ws" | hash_of | cut -c1-6)"
  fi
}
trim_name() { local n="${1:0:$2}"; while [ "${n%-}" != "$n" ]; do n="${n%-}"; done; printf '%s' "$n"; }

worktree_of() {
  git -C "$main" worktree list --porcelain \
    | awk -v ref="refs/heads/$1" '/^worktree / { wt = substr($0, 10) } $0 == "branch " ref { print wt }'
}

# Checks out an existing local or remote branch, or branches off HATJITSU_SANDBOX_BASE (default origin/master).
# npm ci runs on the host, so the app also runs there; the dependencies are plain JavaScript, so the sandbox shares them.
add_worktree() {
  local branch="$1" path="$2"
  [ -e "$path" ] && die "$path already exists but isn't a worktree of $branch."
  git -C "$main" fetch -q origin
  if git -C "$main" show-ref --verify -q "refs/heads/$branch"; then
    git -C "$main" worktree add "$path" "$branch"
  elif git -C "$main" show-ref --verify -q "refs/remotes/origin/$branch"; then
    git -C "$main" worktree add --track -b "$branch" "$path" "origin/$branch"
  else
    git -C "$main" worktree add --no-track -b "$branch" "$path" "${HATJITSU_SANDBOX_BASE:-origin/master}"
  fi
  if command -v npm >/dev/null 2>&1; then
    (cd "$path" && npm ci) || echo "! npm ci failed in $path; run it there by hand"
  else
    echo "! npm is not installed: no dependencies in $path"
  fi
}

# ====================
# msb state
# ====================

SANDBOXES=""   # msb ls, read once per run
refresh_sandboxes() { SANDBOXES="$(msb ls --format json 2>/dev/null || echo '[]')"; }
sandbox_field() { jq -r --arg n "$1" ".[] | select(.name == \$n) | $2" <<<"$SANDBOXES" 2>/dev/null || true; }
sandbox_exists() { [ -n "$(sandbox_field "$name" .name)" ]; }
sandbox_running() { [ "$(sandbox_field "$name" .status)" = Running ]; }
our_sandboxes() { jq -r '.[] | select(.name | startswith("hatjitsu-")) | .name' <<<"$SANDBOXES"; }

# The cache file holds ws= (the checkout) and config= (config_hash when it was created).
cache_file() { mkdir -p "$CACHE_DIR"; echo "$CACHE_DIR/$1"; }
cache_field() { sed -n "s/^$2=//p" "$(cache_file "$1")" 2>/dev/null || true; }
# Everything in tools/sandbox shapes a sandbox (mounts, allowlist, image), so any change makes existing ones stale.
config_hash() { (cd "$REPO" && tree_hash tools/sandbox .tool-versions); }

# ====================
# Helpers
# ====================

die() { echo "✗ $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"; }
need_msb() { need msb "brew install microsandbox"; need jq "brew install jq"; }

hash_of() { git hash-object --stdin | cut -c1-12; }
tree_hash() {
  local p f
  for p in "$@"; do
    [ -e "$p" ] || continue
    find "$p" -type f | LC_ALL=C sort | while read -r f; do printf '%s\n' "$f"; cat "$f"; done
  done | hash_of
}

# Doctor checks: run the command after the label and hint; a failing check sets ok=0 in cmd_doctor.
check() {
  local label="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "✓ $label"; else echo "✗ $label — $hint"; ok=0; fi
}
optional() {
  local label="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "✓ $label"; else echo "! No $label (optional): $hint"; fi
}

# ====================
# Main
# ====================

command -v msb >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && refresh_sandboxes
set_workspace "$REPO"
case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  new) shift; cmd_new "$@" ;;
  setup) cmd_setup ;;
  rm) cmd_rm ;;
  rm-worktree) shift; cmd_rm_worktree "$@" ;;
  prune) cmd_prune ;;
  doctor) cmd_doctor ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
