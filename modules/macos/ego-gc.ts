/**
 * ego-gc — safety net against leaked ego-browser task spaces.
 *
 * Why this exists: every ego-browser task space is a real browser window with
 * its own renderer processes (~0.4-0.8 GB each, measured). The ego-search
 * scripts close their own window, but nothing can run cleanup when a script is
 * killed, the turn is interrupted, or a subagent leaves a window behind. Those
 * are exactly the paths an extension hook can cover and a skill (markdown the
 * model must remember to follow) cannot.
 *
 * Behaviour:
 *   - Counts ego-browser usage from bash commands, so unrelated turns never
 *     spawn the CLI.
 *   - `agent_settled` (the run is really over): sweeps in the background,
 *     throttled, without blocking the end of the turn.
 *   - `session_shutdown`: awaits any in-flight sweep, and sweeps again if usage
 *     happened since the last one — the last chance to release windows.
 *   - `session_start`: clears leftovers from previous sessions (never blocks
 *     startup, throttled by a marker file).
 *   - `/ego-gc`: manual sweep with a status line.
 *   - Never launches ego lite: if the app is not already running there is
 *     nothing to close, so the sweep is skipped (guarded via `pgrep`).
 *   - Only Agent-created spaces are closed. The user's own space is never
 *     touched, and windows kept on purpose (keepSpace:true) are protected by
 *     the keep file the scripts maintain.
 *
 * Disable with PI_EGO_GC=off; debug trail with PI_EGO_GC_DEBUG=1 (→ /tmp/pi-ego-gc.log).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";

const HOME = process.env.HOME ?? "";
const GC_WRAPPER = `${HOME}/.local/bin/ego-gc`;
const GC_SCRIPT = `${HOME}/.pi/agent/skills/ego-search/scripts/gc.js`;
const EGO_BROWSER = `${HOME}/.local/bin/ego-browser`;

const SWEEP_TIMEOUT_MS = 20_000;
const SETTLE_THROTTLE_MS = 60_000;
const STARTUP_THROTTLE_MS = 120_000;
const LAST_SWEEP_FILE = "/tmp/ego-gc-last-sweep";
const DEBUG_FILE = "/tmp/pi-ego-gc.log";

const flag = (value: string | undefined) => ["1", "true", "on"].includes((value ?? "").toLowerCase());
const DISABLED = (process.env.PI_EGO_GC ?? "").toLowerCase() === "off";
const DEBUG = flag(process.env.PI_EGO_GC_DEBUG);

/** Append-only debug trail (opt-in). Never throws. */
const log = (message: string) => {
  if (!DEBUG) return;
  void import("node:fs")
    .then(({ appendFileSync }) => appendFileSync(DEBUG_FILE, `${new Date().toISOString()} ${message}\n`))
    .catch(() => undefined);
};

/** Bash commands that mean "this session touched the browser". */
const EGO_USAGE_RE =
  /\bego-browser\b|ego-search|ego-gc|scripts\/search\.js|scripts\/read\.js|scripts\/gc\.js|\bego\.(?:listTaskSpaces|closeTaskSpace|useTaskSpace)\b/;

type SweepResult = {
  ran: boolean;
  reason: string;
  closed: string[];
  kept: string[];
  failed: string[];
};

const IDLE: SweepResult = { ran: false, reason: "skipped", closed: [], kept: [], failed: [] };

export default function (pi: ExtensionAPI) {
  // Usage counter instead of a boolean: a sweep that started before new ego
  // usage must not mark that later usage as already handled.
  let usageCount = 0;
  let sweptUpTo = 0;
  let inFlight: Promise<SweepResult> | null = null;
  let lastSweepAt = 0;

  log(`extension loaded (pid ${process.pid}, disabled=${DISABLED}, cwd=${process.cwd()})`);

  const egoLiteRunning = async (): Promise<boolean> => {
    try {
      const { code } = await pi.exec("/usr/bin/pgrep", ["-x", "ego lite"], { timeout: 3000 });
      return code === 0;
    } catch {
      return false; // can't tell -> stay conservative and do nothing
    }
  };

  const runSweep = async (): Promise<SweepResult> => {
    if (DISABLED) return { ...IDLE, reason: "disabled (PI_EGO_GC=off)" };
    if (!(await egoLiteRunning())) return { ...IDLE, reason: "ego lite not running" };

    // Prefer the wrapper: it writes fresh params before invoking the sweeper, so
    // a stale /tmp params file can never carry a dryRun into an automatic sweep.
    const hasWrapper = existsSync(GC_WRAPPER);
    if (!hasWrapper && !existsSync(GC_SCRIPT)) return { ...IDLE, reason: `sweeper not installed (${GC_SCRIPT})` };
    const cmd = hasWrapper ? `exec "${GC_WRAPPER}"` : `exec "${EGO_BROWSER}" nodejs < "${GC_SCRIPT}"`;

    try {
      const { stdout, stderr, code, killed } = await pi.exec("/bin/sh", ["-c", cmd], {
        timeout: SWEEP_TIMEOUT_MS,
      });
      if (killed) return { ...IDLE, reason: "sweep timed out" };
      // ego-browser's cliLog writes JSON to stderr; the wrapper merges streams.
      // Parse the first JSON object found in either stream.
      const combined = `${stdout}\n${stderr}`;
      const start = combined.indexOf("{");
      if (start < 0) return { ...IDLE, reason: `no JSON output (exit ${code}: ${combined.trim().slice(0, 120)})` };
      const parsed = JSON.parse(combined.slice(start)) as {
        closed?: Array<{ name: string; id: number }>;
        kept?: Array<{ name: string }>;
        failed?: Array<{ name: string; error?: string }>;
      };
      return {
        ran: true,
        reason: code === 0 ? "ok" : `exit ${code}: ${stderr.trim().slice(0, 120)}`,
        closed: (parsed.closed ?? []).map((s) => `${s.name}#${s.id}`),
        kept: (parsed.kept ?? []).map((s) => s.name),
        failed: (parsed.failed ?? []).map((s) => `${s.name}: ${s.error ?? "error"}`),
      };
    } catch (e) {
      return { ...IDLE, reason: `sweep failed: ${String((e as Error)?.message ?? e).slice(0, 120)}` };
    }
  };

  /**
   * Start (or join) a sweep. `covered` is the usage count the sweep accounts
   * for; when it resolves, anything used after that point still counts as dirty.
   */
  const startSweep = (reason: string): Promise<SweepResult> => {
    if (inFlight) return inFlight;
    const covered = usageCount;
    log(`sweep start (${reason}, covering usage #${covered})`);
    const promise = runSweep()
      .then((result) => {
        sweptUpTo = Math.max(sweptUpTo, covered);
        log(`sweep done (${reason}): ${result.reason} closed=${result.closed.join(",") || "-"}`);
        return result;
      })
      .catch((e) => {
        log(`sweep crashed (${reason}): ${String((e as Error)?.message ?? e)}`);
        return IDLE;
      })
      .finally(() => {
        if (inFlight === promise) inFlight = null;
      });
    inFlight = promise;
    return promise;
  };

  // Never trust a captured ctx: closures that outlive the current run can see a
  // stale context ("ctx is stale after session replacement or reload").
  const safeNotify = async (ctx: { hasUI?: boolean; ui?: { notify?: (m: string, l?: string) => void } }, message: string) => {
    try {
      if (ctx?.hasUI && ctx.ui?.notify) ctx.ui.notify(message, "info");
    } catch {
      /* stale ctx or headless mode — notifications are best-effort */
    }
  };

  pi.on("session_start", async (_event, ctx) => {
    usageCount = 0;
    sweptUpTo = 0;
    lastSweepAt = 0;
    // Self-check: the manual command must be reachable in this session.
    try {
      const names = pi.getCommands().map((c) => c.name);
      log(`/ego-gc registered: ${names.includes("ego-gc")} (${names.length} commands)`);
    } catch (e) {
      log(`getCommands failed: ${String((e as Error)?.message ?? e).slice(0, 160)}`);
    }
    void (async () => {
      // Leftovers from earlier sessions, without delaying startup.
      try {
        const { readFileSync } = await import("node:fs");
        const last = Number(readFileSync(LAST_SWEEP_FILE, "utf8"));
        if (Number.isFinite(last) && Date.now() - last < STARTUP_THROTTLE_MS) return;
      } catch {
        /* no marker yet */
      }
      const result = await startSweep("session_start");
      if (result.ran) {
        try {
          const { writeFileSync } = await import("node:fs");
          writeFileSync(LAST_SWEEP_FILE, String(Date.now()));
        } catch {
          /* marker is best-effort */
        }
      }
      if (result.closed.length > 0) {
        await safeNotify(ctx, `ego-gc: closed ${result.closed.length} leftover browser window(s) from earlier runs`);
      }
    })();
  });

  pi.on("tool_result", async (event) => {
    if (event.toolName !== "bash") return;
    const command = String((event.input as { command?: string } | undefined)?.command ?? "");
    if (EGO_USAGE_RE.test(command)) {
      usageCount += 1;
      log(`usage #${usageCount}: ${command.slice(0, 90)}`);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const dirty = usageCount !== sweptUpTo;
    log(`agent_settled (usage=${usageCount}, swept=${sweptUpTo}, inFlight=${inFlight !== null})`);
    if (!dirty || inFlight) return;
    if (Date.now() - lastSweepAt < SETTLE_THROTTLE_MS) return;
    lastSweepAt = Date.now();
    // Fire-and-forget: never make the user wait at the end of a turn. No ctx in
    // the callback either — by then this run may already be replaced.
    const covered = usageCount;
    void startSweep("agent_settled").then((result) => {
      if (usageCount === covered && result.closed.length > 0) {
        void safeNotify(ctx, `ego-gc: closed ${result.closed.length} leftover browser window(s)`);
      }
    });
  });

  pi.on("session_shutdown", async (event) => {
    const dirty = usageCount !== sweptUpTo;
    log(`session_shutdown (reason=${event.reason}, dirty=${dirty}, inFlight=${inFlight !== null})`);
    if (inFlight) {
      await inFlight; // let an in-flight sweep finish before the process goes away
    }
    if (usageCount !== sweptUpTo) {
      await startSweep("session_shutdown");
    }
    log("shutdown sweep done");
  });

  pi.registerCommand("ego-gc", {
    description: "Close leaked ego-browser Agent windows",
    handler: async (_args, ctx) => {
      const result = await startSweep("command");
      if (!result.ran) {
        await safeNotify(ctx, `ego-gc: nothing swept (${result.reason})`);
        return;
      }
      const parts = [`ego-gc: closed ${result.closed.length}`];
      if (result.kept.length > 0) parts.push(`kept ${result.kept.length} (${result.kept.join(", ")})`);
      if (result.failed.length > 0) parts.push(`failed ${result.failed.join("; ")}`);
      await safeNotify(ctx, parts.join(" · "));
    },
  });
}
