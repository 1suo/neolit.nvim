#!/usr/bin/env node
/**
 * neolit.nvim host shim.
 *
 * Embeds the neolit planned-diff kernel exactly the way the standalone TUI
 * does (AugmentTuiController + CliAgentRuntime, built from the neolit
 * package's dist/) and exposes the controller plus the TUI's pure view model
 * (dist/tui/detail.js) over newline-delimited JSON-RPC 2.0 on stdio, the same
 * framing augmentd uses. The Neovim side renders frames and routes keys; all
 * plan lifecycle, model runtime, apply/commit transactions, and view-model
 * derivation stay here, shared with the TUI.
 *
 * Every state-changing request responds with a fresh frame. Background
 * follow-ups (the automatic approach generation after a task starts) push
 * `neolit/progress` and `neolit/frame` notifications so an idle client still
 * repaints.
 */
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import readline from "node:readline";

const DEFAULT_SPINNER = "⠋";

function parseArguments(argv) {
  const options = { dist: undefined, directory: undefined, stubRuntime: false, noModel: false };
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--dist") options.dist = argv[++index];
    else if (argument === "--directory") options.directory = argv[++index];
    else if (argument === "--stub-runtime") options.stubRuntime = true;
    else if (argument === "--no-model") options.noModel = true;
  }
  return options;
}

function firstLine(value) {
  return String(value ?? "").split(/\r?\n/)[0] ?? "";
}

function rpcError(code, message) {
  return { code, message };
}

const args = parseArguments(process.argv.slice(2));
const dist = args.dist ?? process.env.NEOLIT_DIST;
if (!dist || !fs.existsSync(path.join(dist, "index.js"))) {
  process.stderr.write(`neolit host: no neolit dist at ${dist ?? "(unset)"}. Point --dist (or NEOLIT_DIST) at a neolit checkout with dist/ built (npm run build).\n`);
  process.exit(1);
}

// The nvim host serves its own socket address so a running TUI (or any
// other panel) never starves it: the kernel's default is a single fixed
// path, and a failed bind permanently disables tool sessions. Users can
// still override with AUGMENT_TUI_SOCKET or disable with
// AUGMENT_TUI_NO_SOCKET=1.
{
  const runtime = process.env.XDG_RUNTIME_DIR?.trim();
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  process.env.AUGMENT_TUI_SOCKET ??= runtime
    ? path.join(runtime, "neolit", "augment-nvim.sock")
    : path.join(process.env.TMPDIR ?? "/tmp", `neolit-augment-nvim-${uid}.sock`);
}

const fromDist = (relative) => import(pathToFileURL(path.join(dist, relative)).href);
const { AugmentTuiController, CliAgentRuntime, candidatesForEntry } = await fromDist("index.js");
const { detailLines, entryName, entryState, entryTouchesNode, shortSessionId, shortTaskId, theme } = await fromDist("tui/detail.js");
const { effectiveConfig } = await fromDist("tui/config.js");
const { backendById } = await fromDist("tui/agent-backends.js");
const { ToolSessionDriver, toolSessionSupported } = await fromDist("tui/tool-session.js");

function commandAvailable(command) {
  if (!command) return false;
  if (command.includes("/")) {
    try {
      fs.accessSync(command, fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }
  return (process.env.PATH ?? "").split(path.delimiter).some((directory) => {
    try {
      fs.accessSync(path.join(directory, command), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

/** Deterministic model runtime for tests: singleton domain → one file → a patch that appends a line to session.ts. */
const STUB_PATCH = "--- a/session.ts\n+++ b/session.ts\n@@ -1,2 +1,3 @@\n alpha\n beta\n+gamma\n";
const stubRuntime = {
  async call(request) {
    switch (request.operation) {
      case "generate-domain":
        return { value: { candidates: [{ label: "Edit session", rationale: "direct edit", confidence: 80, touchedPaths: ["session.ts"] }] } };
      case "challenge-domain":
        return { value: { kind: "accept" } };
      case "refine-node":
        return { value: { children: [{ kind: "file", path: "session.ts", lod: "hunk", reason: "apply the edit" }] } };
      case "draft-patch":
        return { value: { patch: STUB_PATCH, assumptions: [] } };
      case "route-message":
        // Tests: a message containing "ambiguous" is classified as an
        // offer-options route with two interpretations; anything else
        // develops the selected path.
        return { value: String(request.context.message ?? "").includes("ambiguous")
          ? {
            intent: "offer-options",
            topic: "rework retries",
            options: [
              { label: "Deadline cutoff", description: "honor a wall-clock deadline" },
              { label: "Fixed count", description: "keep counting attempts" },
            ],
          }
          : { intent: "develop", topic: "stub route", options: [] } };
      default:
        throw new Error(`stub runtime: unexpected operation ${request.operation}`);
    }
  },
};

// Model availability mirrors bin/augment.tsx: env/flags > config file > defaults.
const config = effectiveConfig();
const modelDisabled = args.noModel || process.env.AUGMENT_TUI_NO_MODEL === "1";
const backend = backendById(config.backend ?? "opencode");
const requestedCommand = config.command ?? backend.defaultCommand;
const stub = args.stubRuntime;
const modelInfo = stub
  ? { available: true, label: "STUB" }
  : {
    available: !modelDisabled && commandAvailable(requestedCommand),
    label: config.model ?? `${backend.id} DEFAULT`.toUpperCase(),
  };

// What each role currently routes to, for pickers. Kept in sync by configure.
const runtimeModels = {
  model: config.model ?? null,
  draftModel: config.draftModel ?? null,
  challengeModel: config.challengeModel ?? null,
};

let controller;
let autoGenerated = new Set();
let unsubscribeController;

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function respond(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function respondError(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

function notify(method, params) {
  write({ jsonrpc: "2.0", method, params });
}

/**
 * One render frame: header chips, tree rows with per-segment colors (the same
 * PlannedRow composition as the Ink TUI), the two-section detail pane from
 * detailLines(), the message panel state, and the numbered approach choices
 * open on the selected row. Scrolling, cropping, and selection highlighting
 * belong to the client's windows.
 */
function buildFrame(spinner = DEFAULT_SPINNER) {
  const state = controller.snapshot();
  const selectedRow = controller.selectedRow();
  const live = state.active || state.failed
    ? { spinner, active: state.active, failed: state.failed }
    : undefined;

  const rootStatus = state.task?.nodes[state.task.rootNodeId]?.status;
  const status = state.busy
    ? "BUSY"
    : state.task?.mode === "explanation"
      ? Object.keys(state.task.explanations).length ? "EXPLAINED" : "EXPLAINING"
      : rootStatus ? rootStatus.toUpperCase() : "IDLE";

  const header = {
    left: [
      { text: "NEOLIT", color: theme.primary, bold: true },
      { text: `[${status}]`, color: state.error ? theme.error : status === "IDLE" ? theme.muted : theme.success },
      { text: `${path.basename(state.directory)}${state.branch ? `/${state.branch}` : ""}`, color: theme.secondary },
      ...(state.task ? [{ text: state.agentSession ? `${shortSessionId(state.agentSession)} (${shortTaskId(state.task.id)})` : shortTaskId(state.task.id), color: theme.muted }] : []),
    ],
    right: [{ text: modelInfo.label, color: modelInfo.available ? theme.success : theme.warning }],
  };

  const rows = state.rows.map((row) => {
    const activeRow = entryTouchesNode(row.entry, state.active?.nodeId);
    const failedRow = entryTouchesNode(row.entry, state.failed?.nodeId);
    const marked = row.entry.path !== "." && (state.task
      ? state.task.lockedPaths.some((mark) => row.entry.path === mark || row.entry.path.startsWith(`${mark}/`))
      : state.pendingMarks.includes(row.entry.path));
    const entryViewState = entryState(state.task, row, {
      pendingMarks: state.pendingMarks,
      pendingMode: state.pendingMode,
      appliedDiffIds: state.appliedDiffIds,
      live: activeRow || failedRow
        ? { active: activeRow, failed: failedRow, spinner, operation: state.active?.operation }
        : undefined,
    });
    const segments = [];
    if (row.branch) segments.push({ text: row.branch });
    if (entryViewState.indicator) {
      segments.push({ text: entryViewState.indicator, color: entryViewState.color });
      segments.push({ text: " " });
    }
    segments.push({
      text: entryName(row.entry),
      color: row.repositoryOnly ? theme.muted : row.entry.kind === "dir" ? theme.accent : theme.text,
      bold: !row.repositoryOnly,
    });
    if (entryViewState.suffix) {
      segments.push({ text: " " });
      segments.push({ text: entryViewState.suffix, color: theme.muted });
    }
    return {
      id: row.id,
      directory: row.entry.kind === "dir" || row.entry.kind === "root",
      repositoryOnly: row.repositoryOnly,
      marked,
      segments,
      selected: row.id === state.selectedRowId,
    };
  });

  const detail = detailLines(state.task, selectedRow, {
    pendingMarks: state.pendingMarks,
    pendingMode: state.pendingMode,
    appliedDiffIds: state.appliedDiffIds,
    live,
    filePreview: state.filePreview,
  });

  // Presentation split: with drafted diffs on the selected path, the pane
  // shows the DESCRIPTION section only and the raw patches render in the
  // host's real diff buffer (native diff syntax, treesitter injections).
  // The composed CHANGES block is trimmed at its stable label line; the
  // summary moves to the diff pane's winbar.
  const selectedDiffs = (selectedRow?.entry.diffIds ?? [])
    .map((id) => state.task?.diffs[id])
    .filter(Boolean);
  const changesLabel = detail.findIndex((line) => line.text === "CHANGES");
  let panelDetail = selectedDiffs.length && changesLabel >= 0 ? detail.slice(0, changesLabel) : detail;
  // The section title is presentation, not content: hosts that label the
  // pane themselves (nvim buffer names) would render it twice.
  if (panelDetail.length && panelDetail[0].text === "DESCRIPTION") {
    panelDetail = panelDetail.slice(1);
  }
  const changes = selectedDiffs.map((diff) => ({
    id: diff.id,
    path: diff.path,
    kind: diff.kind,
    applied: state.appliedDiffIds.includes(diff.id),
    text: diff.patch,
  }));
  const kindCounts = selectedDiffs.reduce((counts, diff) => {
    counts[diff.kind] = (counts[diff.kind] ?? 0) + 1;
    return counts;
  }, {});
  const changeSummary = [
    kindCounts.new ? `${kindCounts.new} added` : "",
    kindCounts.modify ? `${kindCounts.modify} changed` : "",
    kindCounts.delete ? `${kindCounts.delete} removed` : "",
  ].filter(Boolean).join(" · ");
  const appliedCount = changes.filter((change) => change.applied).length;

  const choices = candidatesForEntry(state.task, selectedRow?.entry)
    .filter((candidate) => candidate.status === "possible")
    .map((candidate, index) => ({ n: index + 1, candidateId: candidate.id, label: candidate.label }));

  const primaryDiff = (selectedRow?.entry.diffIds ?? [])
    .map((id) => state.task?.diffs[id])
    .find(Boolean);
  const patch = primaryDiff
    ? { diffId: primaryDiff.id, path: primaryDiff.path, text: primaryDiff.patch }
    : null;

  // Live agent-session stream (view-only); the pane shows while a tool
  // session runs and the operator has not hidden it with V. socketPath is
  // carried top-level in the frame.
  const session = {
    lines: state.sessionLines ?? [],
    visible: Boolean(state.toolSession) && state.sessionView !== false,
  };

  return {
    header,
    hasTask: Boolean(state.task),
    taskId: state.task?.id ?? null,
    revision: state.task?.revision ?? null,
    directory: state.directory,
    branch: state.branch ?? null,
    agentSession: state.agentSession ?? null,
    relatedOnly: state.relatedOnly === true,
    filePreview: state.filePreview ?? null,
    socketPath: state.socketPath ?? null,
    models: { ...runtimeModels },
    tree: { rows, selectedRowId: state.selectedRowId ?? null, count: rows.length },
    detail: panelDetail,
    changes: { diffs: changes, summary: changeSummary, applied: appliedCount },
    session,
    patch,
    panel: {
      busy: state.busy,
      operation: state.operation ?? null,
      error: state.error ? firstLine(state.error) : null,
      message: state.message,
    },
    choices,
    routedOptions: state.routedOptions ?? [],
  };
}

function frameWithPanelError(error) {
  const frame = buildFrame();
  frame.panel = { ...frame.panel, error };
  return frame;
}

/**
 * The TUI auto-generates approaches for a fresh change task (augment.tsx's
 * initial effect). Hosts want the same, so the shim owns it: after a task
 * starts (or a persisted task is resumed) with a model available and the root
 * still unresolved, run one crystallize in the background, announcing it with
 * progress and frame notifications.
 */
async function maybeAutoGenerate() {
  const snapshot = controller.snapshot();
  const task = snapshot.task;
  const root = task?.nodes[task.rootNodeId];
  if (!modelInfo.available || !task || task.mode !== "change" || !root || root.status !== "unresolved" || root.candidateIds.length || snapshot.busy || autoGenerated.has(task.id)) return;
  autoGenerated.add(task.id);
  notify("neolit/progress", { operation: "Generating approaches", busy: true });
  try {
    await controller.crystallize();
  } catch {
    // dispatch() already recorded the failure in the panel.
  }
  notify("neolit/frame", buildFrame());
}

function newController(directory) {
  const runtime = stub
    ? stubRuntime
    : modelInfo.available
      ? new CliAgentRuntime({ ...runtimeOptions(), directory })
      : undefined;
  const controller = new AugmentTuiController({
    directory,
    runtime,
    persistTasks: process.env.AUGMENT_TUI_TASKS !== "0",
    challengeRounds: config.challengeRounds,
    // The agent socket stays on by default: external MCP agents attach to
    // this controller's server (`augmentd --mcp --connect <path>`) and their
    // mutations render here as they land. AUGMENT_TUI_NO_SOCKET=1 disables.
  });
  // Mirror bin/augment.tsx: model ops run as prompts in one tool-using
  // agent session per task, streaming into the session pane.
  if (!stub && modelInfo.available && process.env.AUGMENT_TUI_NO_TOOLS !== "1" && toolSessionSupported(backend.id)) {
    controller.useToolSession(new ToolSessionDriver({
      directory,
      backend,
      command: requestedCommand,
      model: config.model,
      timeoutMs: config.timeoutMs,
      server: controller.server,
      socketPath: () => controller.snapshot().socketPath,
    }));
  }
  return controller;
}

/**
 * Push frames for changes that did not originate from a request: external
 * agent mutations adopted while idle. Busy-state animation belongs to the
 * client's spinner polling, so mid-operation refreshes are not pushed.
 */
function watchController() {
  unsubscribeController?.();
  unsubscribeController = controller.subscribe(() => {
    if (!controller.snapshot().busy) notify("neolit/frame", buildFrame());
  });
}

// CliAgentRuntime options are computed once here (mirroring bin/augment.tsx).
function runtimeOptions() {
  return {
    backend,
    command: requestedCommand,
    model: config.model,
    draftModel: config.draftModel,
    challengeModel: config.challengeModel,
    server: config.server,
    agent: config.agent,
    timeoutMs: config.timeoutMs,
  };
}

const methods = {
  async initialize(params) {
    const directory = params.directory ?? args.directory ?? process.cwd();
    if (typeof directory !== "string" || !directory.trim()) throw rpcError(-32602, "initialize requires a repository directory.");
    controller = newController(directory);
    autoGenerated = new Set();
    watchController();
    void maybeAutoGenerate();
    return { frame: buildFrame(), model: modelInfo, agent: controller.runtimeAgent() ?? null, directory };
  },

  frame(params) {
    return buildFrame(typeof params.spinner === "string" && params.spinner ? params.spinner : undefined);
  },

  async move(params) {
    controller.move(Number(params.delta) || 0);
    return buildFrame();
  },

  async select(params) {
    if (typeof params.rowId !== "string") throw rpcError(-32602, "select requires rowId.");
    controller.select(params.rowId);
    return buildFrame();
  },

  async start(params) {
    await controller.start(String(params.objective ?? ""));
    void maybeAutoGenerate();
    return buildFrame();
  },

  /**
   * The single message entry point (the TUI's Enter): one bounded
   * message/route classification decides whether the text develops the
   * selected path, explains around it, or offers interpretations — which
   * `choose` then picks while `routedOptions` is open. An empty text
   * rethinks, and without a task the text starts one.
   */
  async message(params) {
    await controller.route(String(params.text ?? ""));
    return buildFrame();
  },

  async rethink(params) {
    await controller.rethink(typeof params.message === "string" ? params.message : undefined);
    return buildFrame();
  },

  async reopen(params) {
    await controller.reopen(String(params.reason ?? ""));
    return buildFrame();
  },

  async stale(params) {
    await controller.markStale(String(params.path ?? ""));
    return buildFrame();
  },

  async choose(params) {
    // Routed interpretations outrank approach candidates while they are
    // open — the exact precedence of the TUI's number keys.
    const routed = controller.snapshot().routedOptions ?? [];
    const index = (Number(params.n) || 0) - 1;
    if (routed[index]) {
      await controller.chooseRoutedOption(routed[index].label);
      return buildFrame();
    }
    const row = controller.selectedRow();
    const possible = candidatesForEntry(controller.snapshot().task, row?.entry).filter((candidate) => candidate.status === "possible");
    const candidate = possible[index];
    if (!candidate) throw rpcError(-32602, `No approach ${params.n} is open on the selected path.`);
    await controller.selectCandidate(candidate.id);
    return buildFrame();
  },

  async develop() {
    await controller.develop();
    return buildFrame();
  },

  async apply() {
    await controller.applySelected();
    return buildFrame();
  },

  async commit() {
    await controller.commitApplied();
    return buildFrame();
  },

  async lock() {
    await controller.toggleRestriction("lock");
    return buildFrame();
  },

  async allow() {
    await controller.toggleRestriction("allow");
    return buildFrame();
  },

  async configure(params) {
    const update = {
      model: typeof params.model === "string" && params.model ? params.model : undefined,
      draftModel: typeof params.draftModel === "string" && params.draftModel ? params.draftModel : undefined,
      challengeModel: typeof params.challengeModel === "string" && params.challengeModel ? params.challengeModel : undefined,
    };
    controller.configureModels(update);
    for (const role of ["model", "draftModel", "challengeModel"]) {
      if (update[role] !== undefined) runtimeModels[role] = update[role];
    }
    return buildFrame();
  },

  /**
   * Writes an editor-edited patch back into the plan (augmentd patch/set).
   * The controller has no public method for this host operation, so the shim
   * drives the controller's own server and then syncs its private task copy
   * (TS `private` is compile-time only) — the documented seam for hosts that
   * need operations the controller does not wrap yet.
   */
  async patch_set(params) {
    if (!controller) throw rpcError(-32000, "No task is active.");
    const task = controller.snapshot().task;
    if (!task) throw rpcError(-32000, "No task is active.");
    if (typeof params.diffId !== "string" || typeof params.patch !== "string") {
      throw rpcError(-32602, "patch_set requires diffId and patch.");
    }
    const response = await controller.server.handle({
      jsonrpc: "2.0",
      id: 30,
      method: "patch/set",
      params: { taskId: task.id, expectedRevision: task.revision, diffId: params.diffId, patch: params.patch },
    });
    if (!response || "error" in response) {
      throw rpcError(-32000, response?.error?.message ?? "patch/set failed.");
    }
    controller.task = response.result;
    controller.refresh();
    return buildFrame();
  },

  async models() {
    const agent = controller?.runtimeAgent();
    if (!modelInfo.available || !agent) throw rpcError(-32000, "No model runtime is active.");
    try {
      const { availableModels } = await fromDist("tui/setup.js");
      return await availableModels(agent.backendId, agent.command);
    } catch (error) {
      return { models: [], source: `catalog unavailable (${firstLine(error?.message ?? error)}) — type a model id` };
    }
  },

  agent() {
    return controller?.runtimeAgent() ?? null;
  },

  session_toggle() {
    controller?.toggleSessionView();
    return buildFrame();
  },

  cancel() {
    controller?.cancel();
    return { ok: true };
  },

  async shutdown() {
    // Release the agent socket cleanly so the address is free immediately.
    await controller?.dispose();
    return { ok: true };
  },
};

async function handle(message) {
  if (!message || typeof message !== "object" || typeof message.method !== "string") return;
  const isRequest = message.id !== undefined;
  try {
    const handler = methods[message.method];
    if (!handler) throw rpcError(-32601, `Unknown method: ${message.method}`);
    const result = await handler(message.params ?? {});
    if (isRequest) {
      if (message.method === "shutdown") {
        respond(message.id, result);
        setImmediate(() => process.exit(0));
      } else {
        respond(message.id, result);
      }
    }
  } catch (error) {
    if (!isRequest) return;
    if (error && typeof error.code === "number") {
      respondError(message.id, error.code, error.message);
    } else if (controller && message.method !== "initialize") {
      // Controller-level failures surface in the panel exactly like the TUI's
      // run() catch: the frame stays renderable and the error is visible.
      respond(message.id, frameWithPanelError(firstLine(error?.message ?? error)));
    } else {
      respondError(message.id, -32000, firstLine(error?.message ?? error));
    }
  }
}

const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    return;
  }
  void handle(message);
});
lines.on("close", () => {
  void (async () => {
    try {
      await controller?.dispose();
    } catch {
      // best-effort cleanup on the way out
    }
    process.exit(0);
  })();
});
process.stdout.on("error", () => process.exit(0));
