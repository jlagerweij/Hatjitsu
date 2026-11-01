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
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hatjitsu-sandbox"
# A stable path for the host's SSH agent: macOS gives SSH_AUTH_SOCK a new path at every login, but msb keeps the
# path the sandbox was created with.
SSH_LINK="$CACHE_DIR/ssh-agent.sock"
SSH_VSOCK_PORT=2222
KEYCHAIN_SERVICE=hatjitsu-sandbox-claude
LABEL=hatjitsu-sandbox
SANDBOXES=""

# Hosts the sandbox may reach on 443; everything else is blocked.
ALLOWED_HOSTS=(
  # Claude Code, its connectors and its self-update.
  api.anthropic.com
  claude.ai
  statsig.anthropic.com
  downloads.claude.ai
  storage.googleapis.com
  # npm ci / npm install.
  registry.npmjs.org
  github.com
  api.github.com
  codeload.github.com
  raw.githubusercontent.com
  objects.githubusercontent.com
  release-assets.githubusercontent.com
)

MSB_HINT="brew install microsandbox (see https://microsandbox.dev)"
JQ_HINT="brew install jq"

die() { echo "✗ $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"; }

hash_of() { git hash-object --stdin | cut -c1-12; }
tree_hash() {
  local p f
  for p in "$@"; do
    [ -e "$p" ] || continue
    find "$p" -type f | LC_ALL=C sort | while read -r f; do printf '%s\n' "$f"; cat "$f"; done
  done | hash_of
}
node_version() { awk '$1 == "nodejs" { print $2 }' "$REPO/.tool-versions"; }
# The image is built from template/ and the repo's Node version.
TEMPLATE_INPUTS=(tools/sandbox/template .tool-versions)
template_tag() { echo "hatjitsu-sandbox:$(cd "$REPO" && tree_hash "${TEMPLATE_INPUTS[@]}")"; }
# sandbox.sh holds the mounts and the allowlist, so a change to it also makes existing sandboxes stale.
config_hash() { (cd "$REPO" && tree_hash tools/sandbox .tool-versions); }

# Names are lowercase [a-z0-9-], at most 63 chars; a second checkout with the same folder name gets a hash suffix.
set_workspace() {
  ws="$1"
  git_common="$(git -C "$ws" rev-parse --path-format=absolute --git-common-dir)"
  name="hatjitsu-$(basename "$ws" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')"
  name="$(trim_name "${name:0:63}")"
  local owner
  owner="$(sandbox_workspace "$name")"
  if [ -n "$owner" ] && [ "$owner" != "$ws" ]; then
    name="$(trim_name "${name:0:56}")-$(printf '%s' "$ws" | hash_of | cut -c1-6)"
  fi
}
trim_name() { local n="$1"; while [ "${n%-}" != "$n" ]; do n="${n%-}"; done; printf '%s' "$n"; }

# msb doesn't record the workspace, so sandbox.sh keeps it in a cache file per sandbox, with the config hash.
cache_file() { echo "$CACHE_DIR/$1"; }
cache_field() { sed -n "s/^$2=//p" "$(cache_file "$1")" 2>/dev/null || true; }
sandbox_workspace() { cache_field "$1" ws; }

refresh_sandboxes() { SANDBOXES="$(msb ls --format json 2>/dev/null || echo '[]')"; }
sandbox_field() { jq -r --arg n "$1" ".[] | select(.name == \$n) | $2" <<<"$SANDBOXES" 2>/dev/null || true; }
sandbox_exists() { [ -n "$(sandbox_field "$name" .name)" ]; }
sandbox_running() { [ "$(sandbox_field "$name" .status)" = Running ]; }
image_exists() { msb image ls --format json 2>/dev/null | jq -e --arg t "$1" '.[] | select(.reference == $t)' >/dev/null; }

need_msb() {
  need msb "$MSB_HINT"
  need jq "$JQ_HINT"
}

claude_token() { security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true; }

# msb reads secret values from the host environment whenever the sandbox starts; the sandbox only sees placeholders.
export_secrets() {
  CLAUDE_CODE_OAUTH_TOKEN="$(claude_token)"
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || die "No Claude token stored; run: just sandbox-setup"
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  export CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN
  mkdir -p "$CACHE_DIR"
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    ln -sfn "$SSH_AUTH_SOCK" "$SSH_LINK"
  else
    echo "! No SSH agent on the host (SSH_AUTH_SOCK): git over SSH won't work in the sandbox."
  fi
}

create_args() {
  local path rules host
  args=(-n "$name" --label "$LABEL" -m 4G -c 4 -u agent -w "$ws" -H "$name")
  args+=(-e HATJITSU_SANDBOX=1 -e TZ=Europe/Amsterdam -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
  args+=(-v "$ws:$ws")
  # A worktree's git metadata lives in the main checkout's .git.
  case "$git_common" in
    "$ws"/*) ;;
    *) args+=(-v "$git_common:$git_common") ;;
  esac
  # Read-only because the host runs them. .git/config can name commands git runs (core.hooksPath, core.fsmonitor,
  # filters), so it's read-only too.
  for path in "$ws/tools/sandbox" "$git_common/hooks"; do
    [ -d "$path" ] && args+=(-v "$path:$path:ro")
  done
  for path in "$ws/justfile" "$git_common/config" "$ws/.claude/settings.json" "$ws/.claude/settings.local.json"; do
    [ -f "$path" ] && args+=(--mount-file "$path:$path:ro")
  done
  # Deny by default; SSH has no SNI to inspect, so hostname rules need --net-strict=false for github.com:22.
  rules="allow@dns,allow@github.com:tcp:22"
  for host in "${ALLOWED_HOSTS[@]}"; do rules+=",allow@$host:tcp:443"; done
  args+=(--no-net --net-rule "$rules" --net-strict=false)
  args+=(--secret "CLAUDE_CODE_OAUTH_TOKEN@api.anthropic.com,claude.ai")
  [ -n "$GH_TOKEN" ] && args+=(--secret "GH_TOKEN@github.com,api.github.com")
  args+=(--vsock "$SSH_LINK:$SSH_VSOCK_PORT")
  true
}

warn_if_stale() {
  [ "$(cache_field "$name" config)" = "$(config_hash)" ] && return 0
  echo "! $name was created from an older tools/sandbox or .tool-versions. To update it: just sandbox-rm, then"
  echo "  just sandbox. Starting the existing sandbox for now."
}

cmd_run() {
  need_msb
  export_secrets
  if sandbox_exists; then
    warn_if_stale
    sandbox_running || msb start -q "$name"
  else
    local template args
    template="$(template_tag)"
    image_exists "$template" || { echo "Image $template is missing; building it first."; cmd_template; }
    create_args
    msb create -q "${args[@]}" "$template" || die "Creating sandbox $name failed. Run 'just sandbox-doctor'."
    printf 'ws=%s\nconfig=%s\n' "$ws" "$(config_hash)" > "$(cache_file "$name")"
  fi
  msb exec --no-tty -u agent "$name" -- /usr/local/libexec/hatjitsu/startup.sh \
    || echo "! Startup steps failed; see /tmp/hatjitsu-startup.log in the sandbox."
  exec msb exec -t -u agent -w "$ws" "$name" -- claude --dangerously-skip-permissions "$@"
}

# The sandbox is set up by this launcher, not the branch's own copy, which the agent may have changed.
cmd_new() {
  local branch="${1:-}" main root path
  [ -n "$branch" ] || die "Usage: just sandbox-new <branch> [claude args...], e.g. just sandbox-new feature/short-name"
  shift
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "'$branch' is not a valid branch name."
  main="$(dirname "$git_common")"
  root="${HATJITSU_SANDBOX_WORKTREE_ROOT:-$(dirname "$main")}"
  path="$(worktree_of "$branch")"
  if [ -n "$path" ]; then
    echo "$branch is already checked out in $path; using that."
  else
    path="$root/$branch"
    [ -e "$path" ] && die "$path already exists but isn't a worktree of $branch."
    git -C "$main" fetch -q origin
    if git -C "$main" show-ref --verify -q "refs/heads/$branch"; then
      git -C "$main" worktree add "$path" "$branch"
    elif git -C "$main" show-ref --verify -q "refs/remotes/origin/$branch"; then
      git -C "$main" worktree add --track -b "$branch" "$path" "origin/$branch"
    else
      git -C "$main" worktree add --no-track -b "$branch" "$path" "${HATJITSU_SANDBOX_BASE:-origin/master}"
    fi
    install_dependencies "$path"
  fi
  set_workspace "$(git -C "$path" rev-parse --show-toplevel)"
  cmd_run "$@"
}

worktree_of() {
  git -C "$(dirname "$git_common")" worktree list --porcelain \
    | awk -v ref="refs/heads/$1" '/^worktree / { wt = substr($0, 10) } $0 == "branch " ref { print wt }'
}

# On the host, so the app also runs there; Hatjitsu's dependencies are plain JavaScript, so the sandbox shares them.
install_dependencies() {
  command -v npm >/dev/null 2>&1 || { echo "! npm is not installed: no dependencies in $1"; return; }
  (cd "$1" && npm ci) || echo "! npm ci failed in $1; run it there by hand"
}

cmd_setup() {
  need security "Storing the Claude token needs the macOS Keychain."
  need claude "Install Claude Code on the host first."
  local replace=y token
  if [ -n "$(claude_token)" ]; then
    read -rp "Claude: a token is already stored. Replace it? [y/N] " replace
  fi
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
  echo "Sandboxes started from now on get these credentials."
}

cmd_template() {
  need docker "Install a container runtime (Colima, Rancher Desktop or Docker Desktop)."
  local tmp template version
  template="$(template_tag)"
  version="$(node_version)"
  [ -n "$version" ] || die "No nodejs version in $REPO/.tool-versions."
  tmp="$(mktemp -d)"
  docker build --pull --build-arg NODE_VERSION="$version" -t "$template" "$HERE/template" \
    && docker image save "$template" -o "$tmp/image.tar" \
    && msb load -q -i "$tmp/image.tar" -t "$template" \
    || { rm -rf "$tmp"; die "Building image $template failed."; }
  rm -rf "$tmp"
  echo "✓ Image $template loaded. Existing sandboxes keep their old image until recreated."
}

cmd_rm() {
  need_msb
  sandbox_exists || { echo "No sandbox named $name."; rm -f "$(cache_file "$name")"; return 0; }
  msb rm -f -q "$name"
  rm -f "$(cache_file "$name")"
  echo "✓ Removed sandbox $name"
}

# Checks for changes first, so a dirty worktree doesn't lose its sandbox and then fail to be removed.
cmd_rm_worktree() {
  local branch="${1:-}" main path
  [ -n "$branch" ] || die "Usage: just sandbox-rm-worktree <branch>, e.g. just sandbox-rm-worktree feature/short-name"
  main="$(dirname "$git_common")"
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
  local gone n path answer
  gone="$(jq -r '.[] | select(.name | startswith("hatjitsu-")) | .name' <<<"$SANDBOXES" \
    | while read -r n; do path="$(sandbox_workspace "$n")"; [ -n "$path" ] && [ -d "$path" ] || echo "$n"; done)"
  [ -n "$gone" ] || { echo "No sandboxes for removed checkouts."; return 0; }
  echo "Sandboxes whose checkout no longer exists:"
  printf '  %s\n' $gone
  read -rp "Remove them? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing removed."; return 0; }
  for n in $gone; do
    msb rm -f -q "$n" && rm -f "$(cache_file "$n")"
  done
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
has_claude_token() { [ -n "$(claude_token)" ]; }
ssh_agent_works() { [ -S "${SSH_AUTH_SOCK:-}" ] && ssh-add -l; }

cmd_doctor() {
  local ok=1 template
  case "$(uname -s)" in
    Darwin) echo "✓ macOS host" ;;
    *) echo "✗ $(uname -s) host — only macOS is supported (the Claude token lives in the Keychain)"; ok=0 ;;
  esac
  check "msb installed" "$MSB_HINT" command -v msb
  check "msb host setup" "run: msb doctor" msb doctor
  check "jq installed" "$JQ_HINT" command -v jq
  check "docker reachable (builds the image)" "start your container runtime (e.g. colima start)" docker info
  check "Claude token" "run: just sandbox-setup" has_claude_token
  optional "SSH agent with keys" "git over SSH won't work in the sandbox; start ssh-agent and ssh-add your key" ssh_agent_works
  optional "gh login" "Claude can't use gh in the sandbox; run gh auth login" gh auth token
  template="$(template_tag)"
  command -v msb >/dev/null 2>&1 && ! image_exists "$template" && echo "  image $template: built by the next just sandbox"
  echo "  this checkout: $name ($(sandbox_exists && sandbox_field "$name" .status || echo "not created yet"))"
  [ "$ok" = 1 ]
}

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
