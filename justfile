#!/usr/bin/env just --justfile

# List all available recipes with descriptions
default:
    @just --list

# ====================
# Claude Sandbox Commands
# ====================
# See tools/sandbox/README.md.

# Start Claude in this checkout's sandbox (extra args go to claude)
[group('sandbox')]
[positional-arguments]
sandbox *args:
    tools/sandbox/sandbox.sh run "$@"

# Create or reuse a worktree for a branch and start Claude in its sandbox
[group('sandbox')]
[positional-arguments]
sandbox-new branch *args:
    tools/sandbox/sandbox.sh new "$@"

# One-time: store the sandbox's Claude token in the macOS Keychain
[group('sandbox')]
sandbox-setup:
    tools/sandbox/sandbox.sh setup

# Remove this checkout's sandbox
[group('sandbox')]
sandbox-rm:
    tools/sandbox/sandbox.sh rm

# Remove a branch's sandbox and worktree (the branch stays)
[group('sandbox')]
[positional-arguments]
sandbox-rm-worktree branch:
    tools/sandbox/sandbox.sh rm-worktree "$@"

# Remove sandboxes whose checkout or worktree no longer exists
[group('sandbox')]
sandbox-prune:
    tools/sandbox/sandbox.sh prune

# Check the prerequisites for running sandboxes
[group('sandbox')]
sandbox-doctor:
    tools/sandbox/sandbox.sh doctor
