FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source

# Helix editor — fetched from GitHub release as a static binary so we
# don't depend on Debian's helix package state (it currently lags by
# several releases on trixie). Used as $EDITOR by the hermes TUI for
# /memory edit, /config edit, /hooks edit, etc.
FROM debian:13.4 AS helix_source
ARG HELIX_VERSION=25.01.1
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates \
 && curl -fsSL "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-x86_64-linux.tar.xz" \
        -o /tmp/helix.tar.xz \
 && mkdir -p /opt/helix \
 && tar -xJf /tmp/helix.tar.xz -C /opt/helix --strip-components=1 \
 && rm /tmp/helix.tar.xz

FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes . .

# Build web dashboard (Vite outputs to hermes_cli/web_dist/)
RUN cd web && npm run build

# ---------- Python virtualenv ----------
RUN chown hermes:hermes /opt/hermes
USER hermes
# UV_CACHE_DIR redirected outside HERMES_HOME (/opt/data, which is the
# hermes user's $HOME and is later declared as a VOLUME). Some build
# backends (notably kaniko under microk8s with --use-new-run) snapshot
# the user's home directory in a way that leaves the parent
# unwritable for the build USER, breaking uv's default cache at
# $HOME/.cache/uv. /tmp is always writable and discarded after build.
ENV UV_CACHE_DIR=/tmp/uv-cache
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]"

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/helix:/opt/data/.local/bin:${PATH}"
VOLUME [ "/opt/data" ]
# Helix editor — placed last in the main stage so this COPY doesn't
# invalidate the cache of the much heavier npm/playwright/uv layers
# above. EDITOR is set to the absolute path so subprocess invocations
# from the hermes TUI (/memory edit, /config edit, etc.) work even if
# PATH gets mangled in some platform's shell environment.
COPY --from=helix_source /opt/helix /opt/helix
ENV HELIX_RUNTIME=/opt/helix/runtime
ENV EDITOR=/opt/helix/hx
# LLM CLI subagents — Hermes can shell out to these as delegated agents
# using their own subscription auth. Installed late so this layer doesn't
# invalidate the heavier npm/uv/helix cache above.
# USER root so npm install -g can write to /usr/local/lib/node_modules.
# Container will stay as root after this layer (no trailing USER hermes
# below) so the upstream entrypoint can do its uid migration + gosu drop.
USER root
RUN npm install -g --silent \
        @anthropic-ai/claude-code \
        @openai/codex \
        @google/gemini-cli \
 && npm cache clean --force

# Subprocess-friendly env so subagents work when Hermes shells out:
#   - HOME pin so Python/Node subprocesses with cleaned env still find the
#     hermes user's home. Both claude-code and codex default to
#     $HOME/.claude and $HOME/.codey respectively, so HOME alone is enough.
#   - GEMINI_CLI_TRUST_WORKSPACE=true so gemini doesn't refuse to run from
#     non-git CWDs (the agent's terminal tool typically cd's to a sandbox).
ENV HOME=/opt/data
ENV GEMINI_CLI_TRUST_WORKSPACE=true

# Codex requires a flag, not an env var, to bypass the trust check. The
# flag is subcommand-scoped (`codex exec --skip-git-repo-check ...`),
# not global, so a naive `exec real-codex --skip-git-repo-check "$@"`
# wrapper puts the flag in the wrong position. Insert it AFTER the
# subcommand for `exec` (the only command Hermes invokes from a tool
# call); pass other subcommands through unchanged.
RUN mkdir -p /opt/hermes-bin \
 && cat > /opt/hermes-bin/codex <<'WRAP' \
 && chmod +x /opt/hermes-bin/codex
#!/bin/sh
if [ "${1:-}" = "exec" ]; then
  shift
  exec /usr/local/bin/codex exec --skip-git-repo-check "$@"
fi
exec /usr/local/bin/codex "$@"
WRAP
ENV PATH="/opt/hermes-bin:/opt/helix:/opt/data/.local/bin:${PATH}"

# Container intentionally starts as root so the upstream entrypoint can
# usermod the in-image hermes user to HERMES_UID, chown /opt/data, and
# gosu-drop to the configured agent identity. Setting `USER hermes` here
# would cause the entrypoint's `if [ "$(id -u)" = "0" ]` block to skip,
# leaving uid migration broken on every pod start.
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
