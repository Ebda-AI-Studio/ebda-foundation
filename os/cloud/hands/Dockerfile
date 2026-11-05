# Ebda OS hands image (Cloudflare Container, linux/amd64). Build context = os/ (so ops/merge-gate.sh comes along):
#   docker build -f os/cloud/hands/Dockerfile --platform linux/amd64 -t ebda-os-hands os
# wrangler builds it the same way at Task 7 (containers[].image + image_build_context, see README).
# Pinned (all >= 2 weeks old on 2026-11-06): node 22.23.3-bookworm-slim by digest, gh 2.103.0 (sha256-verified),
# Claude Code 2.1.309. NO credentials in the image: CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN, HANDS_TOKEN arrive as env at
# container start (HandsContainer DO, from brain Worker secrets).

ARG NODE_IMAGE=node:22.23.3-bookworm-slim@sha256:3ed98443660ff48413b5af19ecefce3b9d50845a901a43420d47cc63a9fddbe9

# ---- build stage: fetch + verify gh, install the Claude Code CLI ----
FROM ${NODE_IMAGE} AS build
ARG GH_VERSION=2.103.0
ARG GH_SHA256_AMD64=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
ARG GH_SHA256_ARM64=7f322df34e624d14f5ec0c4acb121fd6dfa14392fdbbd1066aa8e0a05ac3721e
ARG CLAUDE_CODE_VERSION=2.1.309
ARG TARGETARCH=amd64
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$TARGETARCH" in amd64) sum="$GH_SHA256_AMD64" ;; arm64) sum="$GH_SHA256_ARM64" ;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; esac; \
    f="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLo "/tmp/$f" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/$f"; \
    echo "$sum  /tmp/$f" | sha256sum -c -; \
    tar -xzf "/tmp/$f" -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /opt/gh
RUN npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# ---- runtime stage ----
FROM ${NODE_IMAGE}
# git for clone/push; python3-minimal for ops/merge-gate.sh (lib/merge_gate.py, stdlib only); ca-certificates for TLS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3-minimal \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/gh /usr/local/bin/gh
COPY --from=build /usr/local/lib/node_modules/@anthropic-ai /usr/local/lib/node_modules/@anthropic-ai
RUN ln -s ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe /usr/local/bin/claude \
 && claude --version && gh --version && git --version
# The OS pieces the hands need, at the same layout as the repo (HANDS_OS_HOME=/opt/ebda-os).
COPY ops/merge-gate.sh /opt/ebda-os/ops/merge-gate.sh
COPY ops/lib/merge_gate.py /opt/ebda-os/ops/lib/merge_gate.py
COPY cloud/hands/run-batch.mjs cloud/hands/entrypoint.sh /opt/ebda-os/cloud/hands/
COPY cloud/hands/lib /opt/ebda-os/cloud/hands/lib
ENV HANDS_SANDBOXED=1 \
    HANDS_OS_HOME=/opt/ebda-os \
    HANDS_WORKDIR=/work \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    NODE_ENV=production
# unprivileged: the image's built-in `node` user (uid 1000); Claude Code refuses bypassPermissions as root
RUN mkdir -p /work && chown node:node /work
USER node
WORKDIR /work
ENTRYPOINT ["/bin/sh", "/opt/ebda-os/cloud/hands/entrypoint.sh"]
