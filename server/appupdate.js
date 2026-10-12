/**
 * Self-update bridge between the dashboard and the host-side updater script
 * (scripts/auto-update.sh, driven by host cron every 15 minutes and on demand).
 *
 * The container has no git/npm and its dist is read-only, so all git work
 * happens on the host through the existing nsenter bridge (same pattern the
 * collectors use for host-only commands). State flows through two files in the
 * repo's config/ directory (bind-mounted rw into the container):
 *
 *   config/auto-update-status.json  — written by the host script, read here
 *   config/settings.json            — settings (autoUpdate, updateDismissedVersion)
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execFile, spawn } from "child_process";
import { getSettings } from "./settings.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, "..");

const STATUS_PATH = process.env.AUTO_UPDATE_STATUS_PATH || path.join(ROOT, "config", "auto-update-status.json");
/** Host path of the repo (where the script + git repo live). Container ROOT is /app. */
const HOST_REPO =
  process.env.SPARKDASH_HOST_REPO ||
  (() => {
    try {
      const st = readStatusFileSync();
      if (st && typeof st.hostRepo === "string" && st.hostRepo) return st.hostRepo;
    } catch {
      /* fall through */
    }
    return "";
  })();
/** Host proc mount used to enter the host namespaces (see collectors). */
const HOST_PROC = process.env.HOST_PROC_PATH || "/host/proc";

/** Parse + sanity-shape a raw status object. Returns null when unusable. */
export function _parseStatus(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const num = (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.floor(v) : null);
  return {
    hostRepo: typeof raw.hostRepo === "string" ? raw.hostRepo : "",
    checkedAt: num(raw.checkedAt) ?? 0,
    updateAvailable: Boolean(raw.updateAvailable),
    behind: num(raw.behind) ?? 0,
    localAhead: num(raw.localAhead) ?? 0,
    current: typeof raw.current === "string" ? raw.current : "",
    latest: typeof raw.latest === "string" ? raw.latest : "",
    latestTag: typeof raw.latestTag === "string" ? raw.latestTag : "",
    currentSha: typeof raw.currentSha === "string" ? raw.currentSha : "",
    updating: Boolean(raw.updating),
    phase: typeof raw.phase === "string" ? raw.phase : "",
    lastResult:
      raw.lastResult && typeof raw.lastResult === "object"
        ? { ok: Boolean(raw.lastResult.ok), at: num(raw.lastResult.at) ?? 0, error: typeof raw.lastResult.error === "string" ? raw.lastResult.error : "" }
        : null,
    lastError: typeof raw.lastError === "string" ? raw.lastError : "",
    supported: Boolean(raw.supported),
  };
}

function readStatusFileSync() {
  return JSON.parse(fs.readFileSync(STATUS_PATH, "utf-8"));
}

/** Latest status from disk, or null when the updater hasn't run yet. */
export function getStatus() {
  try {
    return _parseStatus(readStatusFileSync());
  } catch {
    return null;
  }
}

/** Status older than this is refreshed before being shown. */
const STALE_MS = 10 * 60_000;
/** How long a check command may run (git fetch over the network). */
const CHECK_TIMEOUT_MS = 90_000;

export function isStale(status) {
  return !status || !status.checkedAt || Date.now() - status.checkedAt > STALE_MS;
}

/** True when the container can reach the host (nsenter bridge + repo known). */
export function isSupported() {
  if (!HOST_REPO) return false;
  try {
    // NOTE: HOST_REPO lives on the HOST filesystem — it is intentionally NOT
    // checked with fs.existsSync() here, because that would test the
    // container's own filesystem and always fail. Once nsenter enters the
    // host's mount namespace the path resolves there; the script itself
    // aborts cleanly if the repo is missing.
    return fs.existsSync(path.join(HOST_PROC, "1", "ns", "mnt"));
  } catch {
    return false;
  }
}

/**
 * Build the nsenter argv that runs a command inside the host's mount+net
 * namespaces (same approach as SystemCollector._execOnHostNet).
 */
export function _hostExecArgs(command) {
  return [
    "--mount=" + path.join(HOST_PROC, "1", "ns", "mnt"),
    "--net=" + path.join(HOST_PROC, "1", "ns", "net"),
    "--",
    "/bin/bash",
    "-lc",
    `cd ${JSON.stringify(HOST_REPO)} && ${command}`,
  ];
}

/**
 * Ask the host script to refresh the status file (git fetch + counts).
 * Resolves with the fresh status; throws on failure.
 */
export function checkNow(timeoutMs = CHECK_TIMEOUT_MS) {
  if (!isSupported()) return Promise.reject(new Error("Host update bridge not available"));
  return new Promise((resolve, reject) => {
    execFile("nsenter", _hostExecArgs("scripts/auto-update.sh --check-json"), { timeout: timeoutMs }, (err) => {
      if (err) return reject(err);
      const st = getStatus();
      if (!st) return reject(new Error("Updater wrote no status"));
      resolve(st);
    });
  });
}

/**
 * Fire the host update in the background (detached — the container will be
 * restarted by it mid-flight, so this HTTP call must not wait for it).
 */
export function requestApply() {
  if (!isSupported()) return false;
  const child = spawn("nsenter", _hostExecArgs("scripts/auto-update.sh --apply --ui"), {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  return true;
}

/** GET /api/app/update payload: status + effective prompt decision. */
export function updateView() {
  const settings = getSettings();
  const status = getStatus();
  const supported = isSupported() || Boolean(status);
  const base = {
    supported,
    updating: status?.updating ?? false,
    phase: status?.phase ?? "",
    lastResult: status?.lastResult ?? null,
    lastError: status?.lastError ?? "",
    autoUpdate: Boolean(settings.autoUpdate),
  };
  if (!status) return { ...base, updateAvailable: false, behind: 0, localAhead: 0, current: "", latest: "", prompt: false, stale: true };
  const prompt =
    status.updateAvailable &&
    !status.updating &&
    !base.autoUpdate &&
    status.latestTag !== settings.updateDismissedVersion;
  return {
    ...base,
    updateAvailable: status.updateAvailable,
    behind: status.behind,
    localAhead: status.localAhead,
    current: status.current,
    latest: status.latest,
    latestTag: status.latestTag,
    currentSha: status.currentSha,
    stale: isStale(status),
    prompt,
  };
}

/** Decision used by the host script too — keep the semantics in one place. */
export function shouldAutoApply(status, settings) {
  return Boolean(status?.updateAvailable && settings?.autoUpdate && status.latestTag !== settings?.updateDismissedVersion);
}
