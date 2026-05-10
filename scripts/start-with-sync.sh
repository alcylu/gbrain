#!/usr/bin/env bash
# Boots gbrain HTTP server alongside a bidirectional GitHub sync loop.
#
# Sync flow each cycle (every $SYNC_INTERVAL_SEC seconds):
#   1. git pull origin main           — bring in external commits
#   2. gbrain sync --repo $SYNC_DIR   — filesystem → DB
#   3. gbrain export --dir $SYNC_DIR  — DB → filesystem
#   4. git commit + push if dirty     — propagate Sage's MCP writes back to git
#
# Required env vars:
#   SYNC_SSH_KEY         — OpenSSH private key (deploy key with write access to SYNC_REPO_SSH_URL)
#   SYNC_REPO_SSH_URL    — defaults to git@github.com:alcylu/allen-brain.git
#   SYNC_DIR             — defaults to /tmp/brain
#   SYNC_INTERVAL_SEC    — defaults to 300 (5 minutes)
#   PORT                 — gbrain HTTP server port (Railway sets this)
set -uo pipefail

SYNC_REPO="${SYNC_REPO_SSH_URL:-git@github.com:alcylu/allen-brain.git}"
SYNC_DIR="${SYNC_DIR:-/tmp/brain}"
SYNC_INTERVAL="${SYNC_INTERVAL_SEC:-300}"
PORT_TO_USE="${PORT:-3131}"

log() { printf '[%s] [start-with-sync] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# 1. Install git + ssh client (container is ephemeral; redeploys start fresh)
if ! command -v git >/dev/null 2>&1; then
  log "installing git + openssh-client"
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq git openssh-client >/dev/null 2>&1 || {
    log "FATAL: apt-get install failed"; exit 1; }
fi
log "git: $(git --version)"

# 2. SSH key for git push/pull
SYNC_ENABLED=0
if [ -n "${SYNC_SSH_KEY:-}" ]; then
  mkdir -p /root/.ssh
  printf '%s\n' "${SYNC_SSH_KEY}" > /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519
  ssh-keyscan -t ed25519,rsa github.com >> /root/.ssh/known_hosts 2>/dev/null
  SYNC_ENABLED=1
  log "ssh deploy key configured"
else
  log "WARNING: SYNC_SSH_KEY not set — sync loop will not start"
fi

# 3. Clone allen-brain (skip if already cloned, e.g. across container restart)
if [ "$SYNC_ENABLED" = "1" ]; then
  if [ ! -d "${SYNC_DIR}/.git" ]; then
    log "cloning ${SYNC_REPO} → ${SYNC_DIR}"
    rm -rf "${SYNC_DIR}"
    if git clone --quiet "${SYNC_REPO}" "${SYNC_DIR}" 2>/tmp/clone.err; then
      cd "${SYNC_DIR}"
      git config user.email "gbrain@allen.dev"
      git config user.name "gbrain auto-sync"
      log "cloned $(git log -1 --pretty='%h %s')"
    else
      log "ERROR: clone failed:"; cat /tmp/clone.err
      SYNC_ENABLED=0
    fi
  else
    log "${SYNC_DIR} already exists — reusing existing clone"
  fi
fi

# 4. Background sync loop
if [ "$SYNC_ENABLED" = "1" ]; then
  (
    # First sleep so the server has a moment to start
    sleep 30
    while true; do
      cd "${SYNC_DIR}" 2>/dev/null || { log "sync dir vanished, exiting loop"; break; }

      # Pull external changes (rebase preserves any local-only commits we haven't pushed yet)
      if ! git pull --quiet --rebase --autostash 2>/tmp/pull.err; then
        log "git pull failed, doing hard reset to origin/main:"
        head -3 /tmp/pull.err
        git fetch --quiet 2>/dev/null
        git reset --quiet --hard origin/main 2>/dev/null
      fi

      # Filesystem → DB
      if ! (cd /app && bun run src/cli.ts sync --repo "${SYNC_DIR}" >/tmp/sync.log 2>&1); then
        log "gbrain sync failed:"; tail -8 /tmp/sync.log
        sleep "${SYNC_INTERVAL}"
        continue
      fi

      # DB → filesystem
      if ! (cd /app && bun run src/cli.ts export --dir "${SYNC_DIR}" >/tmp/export.log 2>&1); then
        log "gbrain export failed:"; tail -8 /tmp/export.log
        sleep "${SYNC_INTERVAL}"
        continue
      fi

      # Commit + push if dirty
      cd "${SYNC_DIR}"
      if [ -n "$(git status --short)" ]; then
        git add -A
        git commit -q -m "auto-sync: $(date -u +%FT%TZ)"
        if git push --quiet 2>/tmp/push.err; then
          log "pushed $(git log -1 --pretty='%h')"
        else
          log "git push failed:"; head -3 /tmp/push.err
        fi
      fi

      sleep "${SYNC_INTERVAL}"
    done
  ) &
  log "sync loop started (interval=${SYNC_INTERVAL}s, pid=$!)"
fi

# 5. Hand off to gbrain HTTP server (foreground)
log "starting gbrain server on port ${PORT_TO_USE}"
cd /app
exec bun run src/cli.ts serve --http --port "${PORT_TO_USE}"
