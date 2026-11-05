# Ebda OS hands image (Cloudflare Container, linux/amd64). Build context = os/ (so ops/merge-gate.sh comes along):
#   docker build -f os/cloud/hands/Dockerfile --platform linux/amd64 -t ebda-os-hands os
# wrangler builds it the same way at Task 7 (containers[].image + image_build_context, see README).
# Pinned (all >= 2 weeks old on 2026-11-06): node 22.23.3-bookworm-slim by digest; gh 2.103.0 and gitleaks 8.30.1 by
# sha256; Claude Code 2.1.309 by version + sha512 integrity (claude-cli/package-lock.json, npm ci).
# NO credentials in the image: CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN, HANDS_TOKEN arrive as env at container start
# (HandsContainer DO, from brain Worker secrets).
#
# Privilege split (security S1): the hands (run-batch.mjs) run as root and hold the tokens; everything untrusted
# (Claude Code, the repo's install/test/format commands) runs as the unprivileged `node` user through setpriv
# (HANDS_SANDBOX_USER), so it cannot read the hands' /proc environ, the private askpass dir or the commit tree.

ARG NODE_IMAGE=node:22.23.3-bookworm-slim@sha256:3ed98443660ff48413b5af19ecefce3b9d50845a901a43420d47cc63a9fddbe9

# ---- build stage: fetch + verify gh and gitleaks, install the Claude Code CLI from its lockfile ----
FROM ${NODE_IMAGE} AS build
ARG GH_VERSION=2.103.0
ARG GH_SHA256_AMD64=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
ARG GH_SHA256_ARM64=7f322df34e624d14f5ec0c4acb121fd6dfa14392fdbbd1066aa8e0a05ac3721e
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256_AMD64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ARG GITLEAKS_SHA256_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
ARG CLAUDE_CODE_VERSION=2.1.309
ARG TARGETARCH=amd64
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$TARGETARCH" in amd64) sum="$GH_SHA256_AMD64"; gl="$GITLEAKS_SHA256_AMD64"; glarch=x64 ;; arm64) sum="$GH_SHA256_ARM64"; gl="$GITLEAKS_SHA256_ARM64"; glarch=arm64 ;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; esac; \
    f="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo "/tmp/$f" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/$f"; \
    echo "$sum  /tmp/$f" | sha256sum -c -; \
    tar -xzf "/tmp/$f" -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /opt/gh; \
    g="gitleaks_${GITLEAKS_VERSION}_linux_${glarch}.tar.gz"; \
    curl -fsSLo "/tmp/$g" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/$g"; \
    echo "$gl  /tmp/$g" | sha256sum -c -; \
    mkdir -p /tmp/gl && tar -xzf "/tmp/$g" -C /tmp/gl; \
    install -m 0755 /tmp/gl/gitleaks /opt/gitleaks
COPY cloud/hands/claude-cli/package.json cloud/hands/claude-cli/package-lock.json /opt/claude-cli/
RUN cd /opt/claude-cli \
 && grep -q "\"version\": \"${CLAUDE_CODE_VERSION}\"" package-lock.json \
 && npm ci --omit=dev --no-audit --no-fund \
 && npm cache clean --force

# ---- runtime stage ----
FROM ${NODE_IMAGE}
# git for clone/push; python3-minimal for ops/merge-gate.sh (lib/merge_gate.py, stdlib only); ca-certificates for TLS.
# setpriv comes with util-linux (essential in Debian).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3-minimal \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/gh /usr/local/bin/gh
COPY --from=build /opt/gitleaks /usr/local/bin/gitleaks
COPY --from=build /opt/claude-cli /opt/claude-cli
RUN ln -s /opt/claude-cli/node_modules/.bin/claude /usr/local/bin/claude \
 && claude --version && gh --version && git --version && gitleaks version && setpriv --version
# The OS pieces the hands need, at the same layout as the repo (HANDS_OS_HOME=/opt/ebda-os).
COPY ops/merge-gate.sh /opt/ebda-os/ops/merge-gate.sh
COPY ops/lib/merge_gate.py /opt/ebda-os/ops/lib/merge_gate.py
COPY cloud/hands/run-batch.mjs cloud/hands/entrypoint.sh /opt/ebda-os/cloud/hands/
COPY cloud/hands/lib /opt/ebda-os/cloud/hands/lib
ENV HANDS_SANDBOXED=1 \
    HANDS_SANDBOX_USER=node \
    HANDS_SANDBOX_HOME=/home/node \
    HANDS_GITLEAKS=/usr/local/bin/gitleaks \
    HANDS_OS_HOME=/opt/ebda-os \
    HANDS_WORKDIR=/work \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    NODE_ENV=production
# /work is root-owned: each job's work tree is chowned to `node`, its commit tree and private dir stay root-only.
RUN mkdir -p /work && chmod 0755 /work
# root on purpose: the hands hold the tokens and drop privileges for every untrusted command (HANDS_SANDBOX_USER).
USER root
WORKDIR /work
ENTRYPOINT ["/bin/sh", "/opt/ebda-os/cloud/hands/entrypoint.sh"]
