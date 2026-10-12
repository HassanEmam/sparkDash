#!/usr/bin/env bash
# sparkDash self-updater.
# Runs on the HOST (host cron every 15 min + on demand from the dashboard via
# server/appupdate.js). Keeps the deployment in step with upstream main and
# reports state through config/auto-update-status.json, which the app reads.
#
# Modes:
#   (none)          cron mode: check; auto-apply only when settings.autoUpdate is on
#   --check-json    check + write status file only (used by GET /api/app/update)
#   --apply         apply the update now (auto mode → Telegram on success)
#   --apply --ui    apply now, UI-triggered: no success Telegram (the UI shows it)
#
# Fail-safe by design: on any problem the running container is left untouched,
# the failure lands in the status file (and Telegram), and the app shows it.
set -u
export PATH="/home/hassan/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Resolve the repo this script lives in (works from cron and any cwd).
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOG="$REPO/auto-update.log"
STATE="$REPO/config/auto-update-status.json"
SETTINGS="$REPO/config/settings.json"
STAMP="$(date +%s)"

CONTAINER="${SPARKDASH_CONTAINER:-sparkDash}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
if [ "${SPARKDASH_UPDATE_NOTIFY:-1}" = "0" ]; then notify() { :; }; else
notify() { hermes send -t telegram "sparkDash: $*" >/dev/null 2>&1 || true; }; fi

MODE="${1:-}"
UI_TRIGGERED=false
[ "${2:-}" = "--ui" ] && UI_TRIGGERED=true

# Read a string key from config/settings.json (empty when missing).
setting_str() { python3 -c "
import json,sys
try:
    print(json.load(open('$SETTINGS')).get('$1','') or '')
except Exception:
    print('')
" 2>/dev/null; }

# Only one updater at a time.
exec 9>/tmp/sparkdash-update.lock
flock -n 9 || { log "another update run in progress; exiting"; exit 0; }

cd "$REPO" || { log "FATAL: repo $REPO missing"; notify "repo missing at $REPO — cannot update"; exit 1; }
mkdir -p "$(dirname "$STATE")"

# ── Check phase: fetch upstream and count commits ────────────────────────────
git fetch origin main --quiet || { log "git fetch failed (network?)"; exit 1; }

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
BEHIND="$(git rev-list --count HEAD..origin/main)"
LOCAL_AHEAD="$(git rev-list --count origin/main..HEAD)"
AUTO_UPDATE="$(setting_str autoUpdate)"
AUTO_UPDATE=$([ "$AUTO_UPDATE" = "true" ] && echo true || echo false)

# write_status <updating:true|false> <phase> <lastResultJson-or-null>
write_status() {
  python3 - "$STATE" "$1" "$2" "$3" << 'PYEOF'
import json, sys
state_path, updating, phase, last_result = sys.argv[1], sys.argv[2] == "true", sys.argv[3], json.loads(sys.argv[4])
try:
    st = json.load(open(state_path))
except Exception:
    st = {}
st.update({
    "hostRepo": __import__("os").environ.get("SPARKDASH_HOST_REPO", ""),
    "checkedAt": int(__import__("time").time() * 1000),
    "updateAvailable": st.get("_behind", 0) > 0,
    "behind": st.get("_behind", 0),
    "localAhead": st.get("_localAhead", 0),
    "current": st.get("_current", ""),
    "latest": st.get("_latest", ""),
    "updating": updating,
    "phase": phase,
})
st["lastResult"] = last_result
for k in [k for k in st if k.startswith("_")]:
    del st[k]
json.dump(st, open(state_path, "w"))
PYEOF
}

# Seed private counts into the state file, then render the public status.
seed_and_write() { # seed_and_write <updating> <phase> <lastResultJson>
  python3 - "$STATE" << PYEOF
import json
try:
    st = json.load(open("$STATE"))
except Exception:
    st = {}
st["_behind"] = $BEHIND
st["_localAhead"] = $LOCAL_AHEAD
st["_current"] = "$LOCAL"
st["_latest"] = "$REMOTE"
json.dump(st, open("$STATE", "w"))
PYEOF
  write_status "$1" "$2" "$3"
}

set_phase() { # set_phase <phase> — keep counts, flip updating
  python3 - "$STATE" "$1" << 'PYEOF'
import json, sys
state_path, phase = sys.argv[1], sys.argv[2]
try:
    st = json.load(open(state_path))
    st["updating"] = True
    st["phase"] = phase
    json.dump(st, open(state_path, "w"))
except Exception:
    pass
PYEOF
}

seed_and_write false "idle" "null"

[ "$MODE" = "--check-json" ] && exit 0
[ "$BEHIND" = "0" ] && exit 0  # up to date — silent

DISMISSED="$(setting_str updateDismissedSha)"
SHOULD_APPLY=false
if [ "$MODE" = "--apply" ]; then
  SHOULD_APPLY=true
elif [ "$AUTO_UPDATE" = "true" ] && [ "$REMOTE" != "$DISMISSED" ]; then
  SHOULD_APPLY=true  # auto-update enabled and this version wasn't rejected
fi
[ "$SHOULD_APPLY" = "true" ] || exit 0  # update available but not consented — the app shows the prompt

# ── Apply phase ──────────────────────────────────────────────────────────────
log "applying update: ${LOCAL:0:7} -> ${REMOTE:0:7} (ui=$UI_TRIGGERED)"
[ "$UI_TRIGGERED" = "false" ] && notify "a new version of sparkDash was published — updating now, the dashboard may blip for a few seconds…"

seed_and_write true "starting" "null"

# Clear an interrupted rebase from a previous crashed run.
git rebase --abort 2>/dev/null || true

if ! git rebase origin/main --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null || true
  log "REBASE CONFLICT — keeping the currently running version"
  seed_and_write false "failed" '{"ok": false, "error": "The new version conflicts with your local customisations — nothing was changed."}'
  notify "found a new version but it conflicts with your local customisations, so I left the current version running."
  exit 1
fi

NEW="$(git rev-parse HEAD)"
if [ "$NEW" = "$LOCAL" ]; then
  seed_and_write false "idle" '{"ok": true, "error": ""}'
  exit 0
fi
log "rebased onto ${NEW:0:7}; installing dependencies"

if ! npm install --no-audit --no-fund >>"$LOG" 2>&1; then
  log "npm install FAILED — container NOT restarted, old version still running"
  seed_and_write false "failed" '{"ok": false, "error": "Dependency install failed — the old version is still running."}'
  notify "update failed at 'npm install' — the old version is still running untouched."
  exit 1
fi

set_phase "building"
if ! npm run build >>"$LOG" 2>&1; then
  log "frontend build FAILED — container NOT restarted, old version still running"
  seed_and_write false "failed" '{"ok": false, "error": "Frontend build failed — the old version is still running."}'
  notify "update failed at the build step — the old version is still running untouched."
  exit 1
fi

# Rebuild the image only when dependencies changed (node_modules live in the
# image; server code and dist are bind-mounted from the host).
if git diff --quiet "$LOCAL" "$NEW" -- package.json package-lock.json 2>/dev/null; then
  log "dependencies unchanged — plain restart"
  set_phase "restarting"
  docker restart "$CONTAINER" >/dev/null || { log "docker restart FAILED"; seed_and_write false "failed" '{"ok": false, "error": "Container restart failed."}'; notify "update applied but the container restart failed — check docker."; exit 1; }
else
  log "dependencies changed — rebuilding image (this can take a few minutes)"
  set_phase "rebuilding-image"
  if docker compose build --quiet "$CONTAINER" >>"$LOG" 2>&1 && docker compose up -d --quiet-pull "$CONTAINER" >>"$LOG" 2>&1; then
    log "image rebuilt + container recreated"
  else
    log "image rebuild FAILED — falling back to plain restart with old deps"
    set_phase "restarting"
    docker restart "$CONTAINER" >/dev/null || { log "docker restart FAILED"; seed_and_write false "failed" '{"ok": false, "error": "Container restart failed."}'; notify "update applied but the container restart failed — check docker."; exit 1; }
  fi
fi

# Health check: container binds where BIND_HOST points; read it from .env.
BIND_HOST="$(grep -E '^BIND_HOST=' .env 2>/dev/null | cut -d= -f2-)"
URL="http://127.0.0.1:5555"
[ -n "$BIND_HOST" ] && URL="http://${BIND_HOST}:5555"
HEALTHY=""
for _ in $(seq 1 20); do
  sleep 3
  CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$URL/" 2>/dev/null || true)"
  [ "$CODE" = "200" ] && { HEALTHY=1; break; }
done

if [ -n "$HEALTHY" ]; then
  log "update complete and healthy at $URL"
  seed_and_write false "done" '{"ok": true, "error": ""}'
  [ "$UI_TRIGGERED" = "false" ] && notify "updated to the new version and it's back up and healthy ✅"
else
  log "update applied but health check FAILED at $URL (last code: ${CODE:-none})"
  seed_and_write false "failed" '{"ok": false, "error": "Updated but the health check failed — check docker logs."}'
  notify "updated but the app didn't come back healthy at $URL — ask Hermes to check the logs."
fi
