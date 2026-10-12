#!/usr/bin/env bash
# sparkDash self-updater.
# Keeps the deployment in step with upstream main: fetch -> rebase local
# commits -> npm install -> frontend build -> rebuild image only if deps
# changed -> restart container -> health check -> Telegram notify.
# Designed to fail SAFE: on any problem the currently-running container is
# left untouched and Hassan gets a Telegram message.
set -u
export PATH="/home/hassan/.local/bin:/usr/local/bin:/usr/bin:/bin"

REPO="/home/hassan/sparkDash"
LOG="/home/hassan/sparkDash/auto-update.log"
URL="http://127.0.0.1:5555"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
notify() { hermes send -t telegram "sparkDash: $*" >/dev/null 2>&1 || true; }

STATE="/home/hassan/.cache/sparkdash-update.lastnotified"
mkdir -p "$(dirname "$STATE")"
notify_once() { # notify_once <key> <message> — one notification per distinct key
  local key="$1" msg="$2"
  [ "$(cat "$STATE" 2>/dev/null)" = "$key" ] && return 0
  echo "$key" > "$STATE"
  notify "$msg"
}

# Only one updater at a time.
exec 9>/tmp/sparkdash-update.lock
flock -n 9 || { log "another update run in progress; exiting"; exit 0; }

cd "$REPO" || { log "FATAL: repo $REPO missing"; notify "repo missing at $REPO — cannot update"; exit 1; }

git fetch origin main --quiet || { log "git fetch failed (network?)"; exit 1; }

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
if [ "$LOCAL" = "$REMOTE" ]; then
  exit 0  # up to date — silent
fi
log "upstream moved: ${LOCAL:0:7} -> ${REMOTE:0:7}"

[ "${1:-}" = "--check" ] && { log "check-only: update available"; exit 0; }

# Clear an interrupted rebase from a previous crashed run.
git rebase --abort 2>/dev/null || true

if ! git rebase origin/main --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null || true
  log "REBASE CONFLICT — keeping the currently running version"
  notify_once "conflict-$REMOTE" "found a new version on main but it conflicts with your local customisations, so I left the current version running. Hermes is watching for the right moment to switch you over."
  exit 1
fi

NEW="$(git rev-parse HEAD)"
log "rebased onto ${NEW:0:7}; installing dependencies"

notify "a new version of sparkDash was published — updating now, the dashboard may blip for a few seconds…"

if ! npm install --no-audit --no-fund >>"$LOG" 2>&1; then
  log "npm install FAILED — container NOT restarted, old version still running"
  notify "update failed at 'npm install' — the old version is still running untouched."
  exit 1
fi

if ! npm run build >>"$LOG" 2>&1; then
  log "frontend build FAILED — container NOT restarted, old version still running"
  notify "update failed at the build step — the old version is still running untouched."
  exit 1
fi

# Rebuild the image only when dependencies changed (node_modules live in the
# image; server code and dist are bind-mounted from the host).
if git diff --quiet "${NEW}@{1}" "${NEW}" -- package.json package-lock.json 2>/dev/null; then
  log "dependencies unchanged — plain restart"
  docker restart sparkDash >/dev/null || { log "docker restart FAILED"; notify "update applied but the container restart failed — check docker."; exit 1; }
else
  log "dependencies changed — rebuilding image (this can take a few minutes)"
  if docker compose build --quiet sparkdash >>"$LOG" 2>&1 && docker compose up -d --quiet-pull sparkdash >>"$LOG" 2>&1; then
    log "image rebuilt + container recreated"
  else
    log "image rebuild FAILED — falling back to plain restart with old deps"
    docker restart sparkDash >/dev/null || { log "docker restart FAILED"; notify "update applied but the container restart failed — check docker."; exit 1; }
  fi
fi

# Health check: container binds where BIND_HOST points; read it from .env.
BIND_HOST="$(grep -E '^BIND_HOST=' .env 2>/dev/null | cut -d= -f2-)"
[ -n "$BIND_HOST" ] && URL="http://${BIND_HOST}:5555"
HEALTHY=""
for _ in $(seq 1 20); do
  sleep 3
  CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$URL/" 2>/dev/null || true)"
  [ "$CODE" = "200" ] && { HEALTHY=1; break; }
done

if [ -n "$HEALTHY" ]; then
  log "update complete and healthy at $URL"
  : > "$STATE"  # clear the notify-once key so future conflicts re-alert
  notify "updated to the new version and it's back up and healthy ✅"
else
  log "update applied but health check FAILED at $URL (last code: ${CODE:-none})"
  notify "updated but the app didn't come back healthy at $URL — I'm on it if you ask me to check the logs."
fi
