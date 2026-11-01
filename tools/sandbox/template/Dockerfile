#checkov:skip=CKV_DOCKER_2:Sandbox image for an interactive agent, not a long-running service
# Image for Claude Code in a microsandbox; built and loaded into msb by tools/sandbox/sandbox.sh.
# NODE_VERSION comes from the repo's .tool-versions.
ARG NODE_VERSION=26
FROM node:${NODE_VERSION}-trixie-slim

# Not tracked by Dependabot: update the versions and checksums from each release's checksum file.
ARG JUST_VERSION=1.58.0
ARG JUST_SHA256_X64=4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d
ARG JUST_SHA256_ARM64=748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df
ARG GH_VERSION=2.102.0
ARG GH_SHA256_X64=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
ARG GH_SHA256_ARM64=7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484
ARG RTK_VERSION=v1.1.0
ARG RTK_SHA256_X64=9454ad1b9489daa57ab0a9f4ebe2faaf4dc82b8a0f26c9e5135151abd7c9378d
ARG RTK_SHA256_ARM64=a5c00c3ab0129884bcb757d348afc1a650efa0f4f0769da97c341f28f89719ed

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less openssh-client procps socat tzdata; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) just_a=x86_64-unknown-linux-musl; just_sha="$JUST_SHA256_X64"; gh_a=amd64; gh_sha="$GH_SHA256_X64"; \
             rtk_a=rtk-x86_64-unknown-linux-musl.tar.gz; rtk_sha="$RTK_SHA256_X64" ;; \
      arm64) just_a=aarch64-unknown-linux-musl; just_sha="$JUST_SHA256_ARM64"; gh_a=arm64; gh_sha="$GH_SHA256_ARM64"; \
             rtk_a=rtk-aarch64-unknown-linux-gnu.tar.gz; rtk_sha="$RTK_SHA256_ARM64" ;; \
      *) echo "unsupported architecture"; exit 1 ;; \
    esac; \
    d="$(mktemp -d)"; cd "$d"; \
    get() { curl --proto '=https' --tlsv1.2 -fsSL -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    get just.tgz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${just_a}.tar.gz" "$just_sha"; \
    tar -xzf just.tgz just; install -m 755 just /usr/local/bin/just; \
    get gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_a}.tar.gz" "$gh_sha"; \
    tar -xzf gh.tgz --strip-components=2 "gh_${GH_VERSION}_linux_${gh_a}/bin/gh"; install -m 755 gh /usr/local/bin/gh; \
    get rtk.tgz "https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${rtk_a}" "$rtk_sha"; \
    tar -xzf rtk.tgz rtk; install -m 755 rtk /usr/local/bin/rtk; \
    cd /; rm -rf "$d"; \
    just --version; gh --version; rtk --version

# The node image's uid 1000 user becomes agent, the user Claude runs as.
RUN set -eux; \
    groupmod -n agent node; \
    usermod -l agent -d /home/agent -m -s /bin/bash node; \
    install -d -m 755 /etc/claude-code; \
    printf '%s\n' '{"skipDangerousModePermissionPrompt": true}' > /etc/claude-code/managed-settings.json

COPY startup.sh /usr/local/libexec/hatjitsu/startup.sh
COPY microsandbox.md /home/agent/.claude/rules/microsandbox.md
RUN chmod 755 /usr/local/libexec/hatjitsu/startup.sh && chown -R agent:agent /home/agent/.claude

USER agent
ENV HOME=/home/agent PATH=/home/agent/.local/bin:$PATH LANG=C.UTF-8
WORKDIR /home/agent
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL https://claude.ai/install.sh | bash; \
    claude --version; \
    printf '%s\n' '{"hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true}' > /home/agent/.claude.json; \
    install -d -m 700 /home/agent/.ssh; \
    curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' > /home/agent/.ssh/known_hosts; \
    rtk init -g --auto-patch --no-trust-filters
