import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { _parseStatus, shouldAutoApply, isStale, _hostExecArgs } from "../appupdate.js";

describe("appupdate status parsing", () => {
  it("parses a full status object", () => {
    const s = _parseStatus({
      hostRepo: "/repo",
      checkedAt: 1000,
      updateAvailable: true,
      behind: 1,
      localAhead: 1,
      current: "2.40.0",
      latest: "2.41.0",
      latestTag: "v2.41.0",
      currentSha: "aaa",
      updating: false,
      phase: "idle",
      lastResult: { ok: true, at: 5, error: "" },
    });
    assert.equal(s.updateAvailable, true);
    assert.equal(s.behind, 1);
    assert.equal(s.localAhead, 1);
    assert.equal(s.latestTag, "v2.41.0");
    assert.equal(s.currentSha, "aaa");
    assert.deepEqual(s.lastResult, { ok: true, at: 5, error: "" });
  });

  it("returns null for junk and coerces bad fields", () => {
    assert.equal(_parseStatus(null), null);
    assert.equal(_parseStatus([1, 2]), null);
    assert.equal(_parseStatus("nope"), null);
    const s = _parseStatus({ behind: "many", lastResult: "x", checkedAt: -5 });
    assert.equal(s.behind, 0);
    assert.equal(s.latestTag, "");
    assert.equal(s.currentSha, "");
    assert.equal(s.lastResult, null);
    assert.equal(s.checkedAt, 0);
  });
});

describe("appupdate prompt/apply decision", () => {
  it("auto-applies only when enabled, release present, and not dismissed", () => {
    const st = { updateAvailable: true, latestTag: "v2.41.0" };
    assert.equal(shouldAutoApply(st, { autoUpdate: true, updateDismissedVersion: "" }), true);
    assert.equal(shouldAutoApply(st, { autoUpdate: false, updateDismissedVersion: "" }), false);
    // user rejected this exact release
    assert.equal(shouldAutoApply(st, { autoUpdate: true, updateDismissedVersion: "v2.41.0" }), false);
    // a NEWER release re-prompts even after a rejection
    assert.equal(shouldAutoApply({ updateAvailable: true, latestTag: "v2.42.0" }, { autoUpdate: true, updateDismissedVersion: "v2.41.0" }), true);
    assert.equal(shouldAutoApply({ updateAvailable: false, latestTag: "v2.41.0" }, { autoUpdate: true }), false);
  });

  it("stale when missing, unchecked, or older than the window", () => {
    assert.equal(isStale(null), true);
    assert.equal(isStale({ checkedAt: 0 }), true);
    assert.equal(isStale({ checkedAt: Date.now() - 20 * 60_000 }), true);
    assert.equal(isStale({ checkedAt: Date.now() - 60_000 }), false);
  });
});

describe("appupdate host bridge", () => {
  it("builds nsenter argv into the host repo", () => {
    const argv = _hostExecArgs("scripts/auto-update.sh --check-json");
    assert.equal(argv[argv.length - 3], "/bin/bash");
    assert.equal(argv[argv.length - 2], "-lc");
    assert.match(argv[argv.length - 1], /scripts\/auto-update\.sh --check-json/);
    assert.match(argv[0], /^--mount=/);
  });
});
