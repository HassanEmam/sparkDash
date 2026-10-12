#!/usr/bin/env bash
# sparkDash self-updater — RELEASE channel.
# Runs on the HOST (host cron every 15 min + on demand from the dashboard via
# server/appupdate.js). Tracks GitHub releases (tags), NOT main: an update is
# available when the latest published release tag is NOT already part of the
# local history. Applying = rebase the local commits onto that release tag,
# then npm install → build → (image rebuild only if deps changed) → container
# restart → health check. State flows through config/auto-update-status.json.
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
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

UPSTREAM_REPO="${SPARKDASH_UPSTREAM_REPO:-MiaAI-Lab/sparkDash}"
CONTAINER="${SPARKDASH_CONTAINER:-sparkDash}"
COMPOSE_SERVICE="${SPARKDASH_COMPOSE_SERVICE:-sparkdash}"

# Resolve the repo this script lives in (works from cron and any cwd).
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# ── Never run as root: demote to the repo's owner (cron + the container's
# nsenter bridge arrive as root; running git/npm as root would leave
# root-owned files in the user's repo and git refuses "dubious ownership").
if [ "$(id -u)" = "0" ]; then
  REPO_OWNER="$(stat -c %U "$REPO" 2>/dev/null || true)"
  if [ -n "$REPO_OWNER" ] && [ "$REPO_OWNER" != "root" ]; then
    exec runuser -u "$REPO_OWNER" -- /bin/bash "$0" "$@"
  fi
fi

LOG="$REPO/auto-update.log"
STATE="$REPO/config/auto-update-status.json"
SETTINGS="$REPO/config/settings.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
if [ "${SPARKDASH_UPDATE_NOTIFY:-1}" = "0" ]; then notify() { :; }; else
notify() { hermes send -t telegram "sparkDash: $*" >/dev/null 2>&1 || true; }; fi

MODE="${1:-}"
UI_TRIGGERED=false
[ "${2:-}" = "--ui" ] && UI_TRIGGERED=true

# Read a key from config/settings.json (empty when missing; bools → "true"/"false").
setting_str() { python3 -c "
import json,sys
try:
    v = json.load(open('$SETTINGS')).get('$1','')
    print(str(v).lower() if isinstance(v, bool) else (v or ''))
except Exception:
    print('')
" 2>/dev/null; }

# Only one updater at a time. The lock lives in the repo — NOT /tmp: sticky
# dirs + fs.protected_regular=2 make re-opening a foreign-owned /tmp file
# fail with "bad file descriptor" even for root.
exec 9>"$REPO/.update.lock"
flock -n 9 || { log "another update run in progress; exiting"; exit 0; }

cd "$REPO" || { log "FATAL: repo $REPO missing"; notify "repo missing at $REPO — cannot update"; exit 1; }
mkdir -p "$(dirname "$STATE")"

current_version() { python3 -c "import json;print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "0"; }

# ── Check phase: find the latest published release and compare ───────────────
# SPARKDASH_RELEASE_TAG overrides the lookup entirely (offline/self-tests).
LATEST_TAG="${SPARKDASH_RELEASE_TAG:-}"
if [ -z "$LATEST_TAG" ]; then
  LATEST_TAG="$(gh release view --repo "$UPSTREAM_REPO" --json tagName -q .tagName 2>/dev/null || true)"
fi
if [ -z "$LATEST_TAG" ]; then
  LATEST_TAG="$(curl -sf -m 15 "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
fi
if [ -z "$LATEST_TAG" ]; then
  log "could not determine the latest release (network? gh auth?)"
  exit 1
fi

# Fetch just that tag (force: tags can be re-pointed on re-release).
git fetch origin "refs/tags/$LATEST_TAG:refs/tags/$LATEST_TAG" --force --quiet 2>>"$LOG" || { log "git tag fetch failed"; exit 1; }

TAG_COMMIT="$(git rev-parse "$LATEST_TAG^{commit}" 2>>"$LOG")" || { log "cannot resolve $LATEST_TAG"; exit 1; }
if git merge-base --is-ancestor "$TAG_COMMIT" HEAD 2>/dev/null; then
  HAVE_LATEST=true
else
  HAVE_LATEST=false
fi

CURRENT_VERSION="$(current_version)"
LATEST_VERSION="${LATEST_TAG#v}"
LOCAL_AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
HEAD_SHA="$(git rev-parse HEAD)"

# write_status <haveLatest:true|false> <updating:true|false> <phase> <lastResultJson-or-null>
write_status() {
  python3 - "$STATE" "$1" "$2" "$3" "$4" \
    "$CURRENT_VERSION" "$LATEST_VERSION" "$LATEST_TAG" "$LOCAL_AHEAD" "$HEAD_SHA" << 'PYEOF'
import json, sys
(state_path, have_latest, updating, phase, last_result,
 current_version, latest_version, latest_tag, local_ahead, head_sha) = sys.argv[1:11]
have_latest, updating = have_latest == "true", updating == "true"
last_result = json.loads(last_result)
try:
    st = json.load(open(state_path))
except Exception:
    st = {}
st.update({
    "hostRepo": __import__("os").environ.get("SPARKDASH_HOST_REPO", ""),
    "checkedAt": int(__import__("time").time() * 1000),
    "channel": "release",
    "updateAvailable": not have_latest,
    "behind": 0 if have_latest else 1,
    "localAhead": int(local_ahead),
    "current": current_version,
    "latest": latest_version,
    "latestTag": latest_tag,
    "currentSha": head_sha,
    "updating": updating,
    "phase": phase,
})
st["lastResult"] = last_result
for k in [k for k in st if k.startswith("_")]:
    del st[k]
json.dump(st, open(state_path, "w"))
PYEOF
}

set_phase() { # set_phase <phase> — keep everything else, flip updating
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

write_status "$HAVE_LATEST" false "idle" "null"

[ "$MODE" = "--check-json" ] && exit 0
[ "$HAVE_LATEST" = "true" ] && exit 0  # latest release already in our history — silent

DISMISSED="$(setting_str updateDismissedVersion)"
SHOULD_APPLY=false
if [ "$MODE" = "--apply" ]; then
  SHOULD_APPLY=true
elif [ "$(setting_str autoUpdate)" = "true" ] && [ "$LATEST_TAG" != "$DISMISSED" ]; then
  SHOULD_APPLY=true  # auto-update enabled and this release wasn't rejected
fi
[ "$SHOULD_APPLY" = "true" ] || exit 0  # update available but not consented — the app shows the prompt

# ── Apply phase ──────────────────────────────────────────────────────────────
log "applying update: $LATEST_TAG (ui=$UI_TRIGGERED)"
[ "$UI_TRIGGERED" = "false" ] && notify "a new version of sparkDash was published ($LATEST_VERSION) — updating now, the dashboard may blip for a few seconds…"

write_status "$HAVE_LATEST" true "starting" "null"

# Clear an interrupted rebase from a previous crashed run.
git rebase --abort 2>/dev/null || true

if ! git rebase "$LATEST_TAG" --quiet 2>>"$LOG"; then
  git rebase --abort 2>/dev/null || true
  log "REBASE CONFLICT — keeping the currently running version"
  write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "The new release conflicts with your local customisations — nothing was changed."}'
  notify "found release $LATEST_VERSION but it conflicts with your local customisations, so I left the current version running."
  exit 1
fi

NEW="$(git rev-parse HEAD)"
if [ "$NEW" = "$HEAD_SHA" ]; then
  write_status true false "idle" '{"ok": true, "error": ""}'
  exit 0
fi
PRE_REBASE_SHA="$HEAD_SHA"               # for the deps-changed check below
log "rebased onto ${NEW:0:7} ($LATEST_TAG); installing dependencies"
CURRENT_VERSION="$(current_version)"   # package.json now carries the release's version
HEAD_SHA="$NEW"

if ! npm install --no-audit --no-fund >>"$LOG" 2>&1; then
  log "npm install FAILED — container NOT restarted, old version still running"
  write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "Dependency install failed — the old version is still running."}'
  notify "update to $LATEST_VERSION failed at 'npm install' — the old version is still running untouched."
  exit 1
fi

set_phase "building"
if ! npm run build >>"$LOG" 2>&1; then
  log "frontend build FAILED — container NOT restarted, old version still running"
  write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "Frontend build failed — the old version is still running."}'
  notify "update to $LATEST_VERSION failed at the build step — the old version is still running untouched."
  exit 1
fi

# Rebuild the image only when dependencies changed (node_modules live in the
# image; server code and dist are bind-mounted from the host).
if git diff --quiet "$PRE_REBASE_SHA" "$NEW" -- package.json package-lock.json 2>/dev/null; then
  log "dependencies unchanged — plain restart"
  set_phase "restarting"
  docker restart "$CONTAINER" >/dev/null || { log "docker restart FAILED"; write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "Container restart failed."}'; notify "update applied but the container restart failed — check docker."; exit 1; }
else
  log "dependencies changed — rebuilding image (this can take a few minutes)"
  set_phase "rebuilding-image"
  if docker compose build --quiet "$COMPOSE_SERVICE" >>"$LOG" 2>&1 && docker compose up -d --quiet-pull "$COMPOSE_SERVICE" >>"$LOG" 2>&1; then
    log "image rebuilt + container recreated"
  else
    log "image rebuild FAILED — falling back to plain restart with old deps"
    set_phase "restarting"
    docker restart "$CONTAINER" >/dev/null || { log "docker restart FAILED"; write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "Container restart failed."}'; notify "update applied but the container restart failed — check docker."; exit 1; }
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
  write_status true false "done" '{"ok": true, "error": ""}'
  [ "$UI_TRIGGERED" = "false" ] && notify "updated to $LATEST_VERSION and it's back up and healthy ✅"
else
  log "update applied but health check FAILED at $URL (last code: ${CODE:-none})"
  write_status "$HAVE_LATEST" false "failed" '{"ok": false, "error": "Updated but the health check failed — check docker logs."}'
  notify "updated to $LATEST_VERSION but the app didn't come back healthy at $URL — ask Hermes to check the logs."
fi
