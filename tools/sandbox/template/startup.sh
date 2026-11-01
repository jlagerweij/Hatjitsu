#!/bin/sh
# Runs as agent at every start of the sandbox (sandbox.sh calls it before starting Claude). Idempotent.
exec >> /tmp/hatjitsu-startup.log 2>&1
echo "== $(date)"

# Bridges the host's SSH agent, exposed by msb on vsock port 2222 (host CID 2), to a unix socket.
# The rootfs (and so /tmp) survives a restart, so check for the process, not the socket file.
if [ -n "$SSH_AUTH_SOCK" ] && ! pgrep -f "VSOCK-CONNECT:2:2222" > /dev/null; then
  rm -f "$SSH_AUTH_SOCK"
  nohup socat "UNIX-LISTEN:$SSH_AUTH_SOCK,fork,mode=600" VSOCK-CONNECT:2:2222 > /tmp/ssh-agent-bridge.log 2>&1 &
  i=0; until [ -S "$SSH_AUTH_SOCK" ] || [ $i -ge 20 ]; do sleep 0.1; i=$((i + 1)); done
  echo "ssh-agent bridge: $([ -S "$SSH_AUTH_SOCK" ] && echo up || echo failed)"
fi

# A self-update only takes effect on the next start, which would leave the first session behind.
claude update > /tmp/claude-update.log 2>&1 || echo "claude update failed (see /tmp/claude-update.log)"
echo "startup complete"
