/**
 * Host shim end-to-end tests: spawn host/host.mjs against the real neolit
 * dist with its deterministic stub model runtime (and a no-model mode for
 * pure tree operations), then drive the JSON-RPC protocol the Neovim client
 * speaks. Run with `npm test` (node --test).
 */
import test from "node:test";
import assert from "node:assert";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline";

const here = path.dirname(fileURLToPath(import.meta.url));
const hostScript = path.join(here, "..", "host", "host.mjs");
const dist = process.env.NEOLIT_TEST_DIST
  ?? path.resolve(here, "..", "..", "neolit", "dist");
assert.ok(fs.existsSync(path.join(dist, "index.js")), `no neolit dist at ${dist} (build neolit or set NEOLIT_TEST_DIST)`);

const temporaryDirectories = [];
const liveClients = [];
test.after(() => {
  for (const client of liveClients) client.child.kill("SIGTERM");
  for (const directory of temporaryDirectories) fs.rmSync(directory, { recursive: true, force: true });
});

function fixtureRepo() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "neolit-host-"));
  temporaryDirectories.push(directory);
  const git = (args) => execFileSync("git", ["-C", directory, ...args], { stdio: "ignore" });
  git(["init", "-q"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "test"]);
  fs.writeFileSync(path.join(directory, "session.ts"), "alpha\nbeta\n");
  git(["add", "session.ts"]);
  git(["commit", "-q", "-m", "init"]);
  return directory;
}

class HostClient {
  constructor(directory, options = {}) {
    this.notifications = [];
    this.pending = new Map();
    this.nextId = 1;
    this.exitCode = new Promise((resolve) => {
      this.child = spawn(process.execPath, [
        hostScript,
        "--dist", dist,
        ...(options.stub ? ["--stub-runtime"] : []),
        ...(options.noModel ? ["--no-model"] : []),
        "--directory", directory,
      ], {
        cwd: directory,
        env: {
          ...process.env,
          AUGMENT_TUI_TASKS: "0",
          ...(options.env ?? {}),
          ...(options.noModel ? { AUGMENT_TUI_NO_MODEL: "1" } : {}),
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      this.child.on("exit", (code) => resolve(code));
      this.child.stderr.on("data", (chunk) => process.stderr.write(`[host stderr] ${chunk}`));
      liveClients.push(this);
      const lines = readline.createInterface({ input: this.child.stdout });
      lines.on("line", (line) => {
        if (!line.trim()) return;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          return;
        }
        if (message.id !== undefined && this.pending.has(message.id)) {
          const { resolve: settle } = this.pending.get(message.id);
          this.pending.delete(message.id);
          settle(message);
        } else if (message.method) {
          this.notifications.push(message);
        }
      });
    });
  }

  write(raw) {
    this.child.stdin.write(raw);
  }

  request(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, { resolve });
      this.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  /** Polls `frame` requests until the predicate holds or the timeout lapses. */
  async waitFor(predicate, { timeoutMs = 10_000, label = "condition" } = {}) {
    const deadline = Date.now() + timeoutMs;
    let last;
    while (Date.now() < deadline) {
      const message = await this.request("frame");
      if (message.result) {
        last = message.result;
        if (predicate(last)) return last;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`timed out waiting for ${label}; last panel: ${JSON.stringify(last?.panel)}`);
  }

  async shutdown() {
    const message = await this.request("shutdown");
    this.write("\n");
    const code = await Promise.race([
      this.exitCode,
      new Promise((resolve) => setTimeout(() => resolve("timeout"), 2000)),
    ]);
    if (code === "timeout") this.child.kill("SIGTERM");
    return message;
  }
}

test("initialize renders the repository tree with stub model info", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  const message = await client.request("initialize", { directory });
  assert.ok(message.result, `initialize failed: ${JSON.stringify(message)}`);
  assert.equal(message.result.model.available, true);
  assert.equal(message.result.model.label, "STUB");
  const frame = message.result.frame;
  assert.ok(frame.tree.rows.some((row) => row.id === "entry:session.ts"), "tree contains repository file");
  assert.equal(frame.tree.rows[0].directory, true, "root row is a directory");
  assert.ok(frame.tree.rows.some((row) => row.id === "entry:session.ts" && row.directory === false), "file rows are not directories");
  assert.ok(frame.tree.rows.every((row) => typeof row.repositoryOnly === "boolean"), "rows carry the repositoryOnly flag");
  assert.equal(frame.hasTask, false);
  assert.ok(frame.panel.message.length > 0, "panel carries the standing message");
  assert.deepEqual(frame.choices, []);
  await client.shutdown();
});

test("full flow: start auto-adopts, develop refines then drafts, apply and commit", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });

  const started = await client.request("start", { objective: "add gamma line" });
  assert.ok(started.result, `start failed: ${JSON.stringify(started)}`);

  const adopted = await client.waitFor(
    (frame) => frame.panel.message?.includes("Single viable approach adopted"),
    { label: "singleton adoption" },
  );
  assert.ok(adopted.tree.rows.some((row) => row.id === "entry:session.ts"));

  await client.request("develop");
  await client.waitFor((frame) => frame.tree.selectedRowId === "entry:session.ts", { label: "refine selects the planned child" });
  const detail = await client.request("select", { rowId: "entry:session.ts" });
  assert.ok(detail.result.detail.some((line) => line.text.includes("apply the edit")), "detail explains the child");

  await client.request("develop");
  await client.waitFor((frame) => frame.panel.message?.includes("Draft change ready"), { label: "patch draft" });
  const drafted = await client.request("select", { rowId: "entry:session.ts" });
  assert.ok(drafted.result.detail.some((line) => line.text.includes("+gamma")), "detail shows the exact patch");

  // Editor round-trip: patch/set writes an edited diff back into the plan.
  assert.ok(drafted.result.patch, "frame carries the selected path's patch");
  const edited = drafted.result.patch.text.replace("+gamma", "+gamma!");
  const rewritten = await client.request("patch_set", { diffId: drafted.result.patch.diffId, patch: edited });
  assert.ok(rewritten.result.patch.text.includes("+gamma!"), "edited patch is stored");
  const reapplied = await client.request("apply");
  assert.ok(reapplied.result.panel.message.includes("Applied 1 drafted change"), reapplied.result.panel.message);
  assert.equal(fs.readFileSync(path.join(directory, "session.ts"), "utf8"), "alpha\nbeta\ngamma!\n");

  const committed = await client.request("commit");
  assert.ok(committed.result.panel.message.includes("Committed 1 applied path"), committed.result.panel.message);
  const subject = execFileSync("git", ["-C", directory, "log", "-1", "--format=%s"], { encoding: "utf8" }).trim();
  assert.equal(subject, "augment: add gamma line");
  const status = execFileSync("git", ["-C", directory, "status", "--porcelain"], { encoding: "utf8" });
  assert.equal(status.trim(), "", "nothing left dirty");
  await client.shutdown();
});

test("restrictions mark paths and surface the lock chip", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });
  await client.request("start", { objective: "lock a path" });
  await client.waitFor((frame) => frame.panel.message?.includes("Single viable approach adopted"), { label: "adoption" });

  const locked = await client.request("select", { rowId: "entry:session.ts" }).then(() => client.request("lock"));
  assert.ok(locked.result.panel.message.includes("Locked: session.ts"), locked.result.panel.message);
  assert.ok(locked.result.header.left.some((chip) => chip.text.includes("[LOCK 1]")), "header shows the lock chip");

  const unlocked = await client.request("lock");
  assert.ok(unlocked.result.panel.message.includes("No marked paths"), unlocked.result.panel.message);
  await client.shutdown();
});

test("no-model mode: start warns and rethink explains there is nothing to rethink", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { noModel: true });
  const message = await client.request("initialize", { directory });
  assert.equal(message.result.model.available, false);

  const started = await client.request("start", { objective: "browse only" });
  assert.ok(started.result.panel.message.includes("No model is configured"), started.result.panel.message);
  assert.equal(started.result.hasTask, true);

  const rethought = await client.request("rethink", { message: "" });
  assert.equal(rethought.result.panel.error, "No model is configured; there is nothing to rethink.");
  await client.shutdown();
});

test("model ops degrade without a live agent runtime", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });

  assert.equal((await client.request("agent")).result, null);
  const models = await client.request("models");
  assert.ok(models.error, "models reports no runtime");
  const configure = await client.request("configure", { model: "x/y" });
  assert.equal(configure.result.panel.error, "The active runtime does not support live model switching.");
  await client.shutdown();
});

test("malformed lines are ignored and the protocol keeps working", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });
  client.write("this is not json\n");
  client.write("{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{}}\n");
  const frame = await client.request("frame");
  assert.ok(frame.result, "protocol survives garbage");
  await client.shutdown();
});

test("unknown methods return a JSON-RPC error", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });
  const message = await client.request("nope/nope");
  assert.equal(message.error.code, -32601);
  await client.shutdown();
});

test("frame exposes runtime models and configure updates them", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  const initialized = await client.request("initialize", { directory });
  const before = initialized.result.frame.models;
  assert.ok(before && typeof before === "object", "frame carries runtime models");
  const configured = await client.request("configure", { model: "test/switched" });
  assert.equal(configured.result.models.model, "test/switched");
  assert.equal(configured.result.models.draftModel, before.draftModel, "untouched roles keep their value");
  await client.shutdown();
});

test("shutdown exits the process cleanly", async () => {
  const directory = fixtureRepo();
  const client = new HostClient(directory, { stub: true });
  await client.request("initialize", { directory });
  const message = await client.shutdown();
  assert.deepEqual(message.result, { ok: true });
  const code = await client.exitCode;
  assert.equal(code, 0);
});
