import { useCallback, useEffect, useRef, useState } from "react";
import { BoltIcon } from "../ui/icons";
import { applyAppUpdate, dismissAppUpdate, fetchAppUpdate } from "../../api/client";
import type { AppUpdateStatus } from "../../api/client";

/**
 * Self-update banner.
 *
 * - Update available (and auto-update off): "Update now" / "Later" — "Later"
 *   records the rejected sha server-side so the prompt stays away until the
 *   next new version.
 * - While the host updater runs: live phase (the container restarts mid-update,
 *   so the page may briefly lose the socket — polling resumes when it's back).
 * - Auto-update on: no prompt; the updater applies releases on its own schedule.
 */

const POLL_MS = 60_000;
const POLL_BUSY_MS = 3_000;

export function UpdateBanner() {
  const [status, setStatus] = useState<AppUpdateStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [showResult, setShowResult] = useState(false);
  const mounted = useRef(true);
  const wasUpdating = useRef(false);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const refresh = useCallback(async () => {
    try {
      const s = await fetchAppUpdate();
      if (mounted.current) setStatus(s);
    } catch {
      /* server restarting or unreachable — next tick retries */
    }
  }, []);

  useEffect(() => {
    void refresh();
    const t = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(t);
  }, [refresh]);

  // While an update runs, poll fast so the phase / result shows promptly.
  useEffect(() => {
    if (!status?.updating && !wasUpdating.current) return;
    if (status?.updating) wasUpdating.current = true;
    const t = window.setInterval(() => void refresh(), POLL_BUSY_MS);
    return () => window.clearInterval(t);
  }, [status?.updating, refresh]);

  // The container restarts at the end of an update — when `updating` flips
  // back to false, surface the recorded result once.
  useEffect(() => {
    if (wasUpdating.current && status && !status.updating) {
      wasUpdating.current = false;
      setShowResult(true);
    }
  }, [status?.updating, status]);

  const apply = useCallback(async () => {
    setBusy(true);
    try {
      await applyAppUpdate();
      wasUpdating.current = true;
      await refresh();
    } catch {
      /* banner stays; next poll retries */
    } finally {
      setBusy(false);
    }
  }, [refresh]);

  const dismiss = useCallback(async () => {
    setBusy(true);
    try {
      await dismissAppUpdate();
      setStatus((s) => (s ? { ...s, prompt: false } : s));
    } catch {
      /* keep showing; next poll refreshes */
    } finally {
      setBusy(false);
    }
  }, []);

  if (!status?.supported) return null;

  const updating = status.updating;
  const result = showResult ? status.lastResult : null;

  if (!updating && !result && !status.prompt) return null;

  return (
    <div
      role="status"
      aria-label="sparkDash update"
      className="fixed inset-x-3 bottom-[76px] z-50 mx-auto flex max-w-md items-center gap-3 rounded-xl border p-3 shadow-lg sm:inset-x-auto sm:bottom-4 sm:left-4"
      style={{
        background: "var(--color-surface-elevated)",
        borderColor: "var(--color-border-strong)",
        color: "var(--color-text)",
      }}
    >
      <BoltIcon className="h-5 w-5 shrink-0 text-accent" />
      {updating ? (
        <div className="min-w-0 flex-1 text-sm leading-tight">
          <span className="font-medium" style={{ color: "var(--color-text-strong)" }}>
            Updating sparkDash…
          </span>
          <span className="block text-xs" style={{ color: "var(--color-muted)" }}>
            {status.phase === "building"
              ? "Building the new version…"
              : status.phase === "rebuilding-image"
                ? "Rebuilding the container image (a few minutes)…"
                : status.phase === "restarting" || status.phase === "starting" || status.phase === "installing"
                  ? "Installing and restarting…"
                  : "Working…"}
          </span>
        </div>
      ) : result ? (
        <div className="min-w-0 flex-1 text-sm leading-tight">
          <span className="font-medium" style={{ color: "var(--color-text-strong)" }}>
            {result.ok ? "sparkDash updated ✓" : "Update didn't finish"}
          </span>
          {!result.ok && (
            <span className="mt-0.5 block text-xs" style={{ color: "var(--color-muted)" }}>
              {result.error || "The current version is still running."}
            </span>
          )}
        </div>
      ) : (
        <>
          <div className="min-w-0 flex-1 text-sm leading-tight">
            <span className="font-medium" style={{ color: "var(--color-text-strong)" }}>
              New version available
            </span>
            <span className="block text-xs" style={{ color: "var(--color-muted)" }}>
              Version {status.latest} is available (you have {status.current}). Update the dashboard now?
            </span>
          </div>
          <button
            type="button"
            onClick={apply}
            disabled={busy}
            className="shrink-0 rounded-lg px-3 py-1.5 text-sm font-medium disabled:opacity-60"
            style={{ background: "var(--color-accent)", color: "var(--color-on-accent)" }}
          >
            {busy ? "…" : "Update now"}
          </button>
          <button
            type="button"
            onClick={dismiss}
            disabled={busy}
            aria-label="Skip this version"
            className="shrink-0 rounded-md px-1.5 py-1 text-sm"
            style={{ color: "var(--color-muted)" }}
          >
            ✕
          </button>
        </>
      )}
      {(result || updating) && (
        <button
          type="button"
          onClick={() => setShowResult(false)}
          aria-label="Dismiss"
          className="shrink-0 rounded-md px-1.5 py-1 text-sm"
          style={{ color: "var(--color-muted)" }}
        >
          ✕
        </button>
      )}
    </div>
  );
}
