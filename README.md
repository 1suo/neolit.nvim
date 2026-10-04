# neolit.nvim

Neovim host for [neolit](https://github.com/1suo/neolit), the planned-diff
augmentation kernel.
The plugin gives Neovim the same operational plane as the standalone `augment`
TUI: the repository tree with integrated plan state on the left, the
DESCRIPTION/CHANGES detail pane on the right, the message panel below, and the
same key set driving the same controller.

It does not reimplement the TUI. A small Node **host shim**
(`host/host.mjs`) embeds the exact classes the TUI embeds —
`AugmentTuiController`, `CliAgentRuntime`, and the pure view model from
`dist/tui/detail.js` — from a built neolit checkout, and speaks
newline-delimited JSON-RPC 2.0 over stdio (the `augmentd` framing). The Lua
side only renders frames into native windows and routes keys. Plan lifecycle,
model routing, retries, apply/commit transactions, and pane formatting stay
single-sourced in the neolit package.

## Requirements

- Neovim ≥ 0.10 (float titles, `vim.ui`, `vim.json`)
- Node ≥ 22.12
- A neolit checkout with `dist/` built (`npm run build`), or an npm-installed
  `neolit`
- Optional: an agent CLI on PATH (`opencode`, `claude`, or `codex`) for model
  operations. Without one, the panel opens in browse-only "NO MODEL" mode —
  pure tree operations still work.

## Install

```lua
{
  "1suo/neolit.nvim",
  opts = {}, -- see Configuration
  cmd = { "Neolit", "NeolitClose" },
}
```

Run `:Neolit` inside the repository you want to plan a change for
(`:Neolit add retry bounds` starts a task immediately, like
`augment "add retry bounds"`). `Q` closes the panel and shuts the host down;
with task persistence on (default), the active task is resumed on next open,
exactly like restarting the TUI.

The `neolit` package is located by trying, in order: the `neolit_dir` option,
`$NEOLIT_DIR`, a `neolit` directory next to this plugin, then the npm global
root.

## Layout

The panel takes over the whole editor — your windows close for the visit and
`Q` reopens their buffers afterwards (the panel is tree | diff | description,
so keeping a working buffer beside it only squeezed every column):

```text
┌─ FILES ───┬─ CHANGES ────────┬─ DESCRIPTION ─────┐
│ ◆ repo/78%│ --- session.ts   │ make retries      │
│ └─ src/   │ +++ session.ts   │ bounded …         │
│           │ @@ +gamma        │───────────────────│
│           │                  │ SESSION (stream)  │
└───────────┴──────────────────┴───────────────────┘
```

- `:Neolit` opens the tree sidebar, a full-height **diff column** (present
  while drafted patches exist; without one the description column owns the
  whole remaining width — diff where it exists, description everywhere else),
  and the **description column**, with a bounded **SESSION stream pane**
  splitting under the description while an agent session runs. All are real
  windows, so standard `<C-w>` motion, resizing, and `:q` behave normally —
  manual resizes stick until the diff column (dis)appears. `Q` closes the
  panel and restores the buffers the takeover closed; closing the sidebar
  does the same. The diff column is a real `filetype=diff` buffer — native
  diff syntax follows your colorscheme's own diff groups, with treesitter
  language injections once the diff parser is installed; on top, full-width
  red/green backgrounds (`DiffAdd`/`DiffDelete`) and the source language's
  syntax inside added and deleted blocks, with the change summary and
  applied count in the diff column's winbar.
- Colors follow the active colorscheme by default: every group links to a
  semantic target (Special, Directory, diffAdded, WarningMsg, Comment,
  Visual for the selected row). Set `palette = "tui"` for the terminal
  TUI's exact colors instead.
- Status, directory/branch, session(task), and model chips live in the
  sidebar's **winbar**; while an operation runs, the winbar shows the spinner
  and operation instead, and a quiet `· related` suffix marks an active
  related filter (either the host's plan-only toggle or the kernel's).
  Messages and errors go through **`vim.notify`**.
- The diff column is the content column: drafted patches with native diff
  syntax, a repository-only file's own body (with its filetype's syntax)
  when selected, or — with `M` — the drafted patch expanded over the whole
  file body, marked `merged into file body` in the winbar.
- Both panes carry identical buffer-local keymaps (the analog of the TUI's
  global input handler), so every key behaves the same in either pane.
- The tree selection is the cursor line (`cursorline` highlight,
  window-local `scrolloff` keeps it centered); the detail pane wraps and
  scrolls with `j`/`k` while focused.
- Indicators (`◆ ~ + - ✓ ! # ● ? ○ ◐` …) and the two-section detail pane come from
  the TUI's view model; their meaning is canonical in
  [neolit's TUI README](https://github.com/1suo/neolit/blob/main/src/tui/README.md).
- All panel keymaps carry `desc` fields, so which-key lists them natively.

## Keys

Same operations as the TUI, with `Tab`/`Esc` added:

```text
j k    move selection (tree pane) or scroll detail (detail pane)
Enter  prompt for the selected path — the message is routed by one bounded
       model call: a task message regenerates its subtree (empty submit
       rethinks), an explanation explains around the path, an ambiguous one
       offers interpretations rendered in the description dock
1-9    choose the numbered approach, or the numbered interpretation of an
       offered route while one is open
D      develop the selected path and everything under it — a chosen approach
       expands into files, then every undrafted file below is drafted in ONE
       batched model call (validated all-or-nothing; per-file fallback marks
       failures × and summarizes "Drafted n/m — press D to retry")
A      apply drafted patch to the working tree (git-apply preflighted as one
       unit; nothing is staged)
C      commit the session-applied paths only (pathspec commit; unrelated
       dirty or staged files stay untouched)
L / W  mark/unmark the selected path in the restriction plain (lock / allow
       polarity; the other key inverts the plain)
M      switch the live runtime's default/draft/challenge model — role picker
       shows current models, then provider → model steps over the backend's
       catalog (cached 5 minutes; typed fallback when no catalog)
N      new change task
O      reopen selected node with a reason
S      mark a real path changed outside the plan
o      open the selected file as a real buffer (falls back to its patch
       buffer for drafted new files; directories fold)
p      edit the selected path's drafted patch as a diff buffer — :w saves it
       back into the plan through patch/set
za/zc/zo  toggle/close/open the directory under the cursor (o and F also
       toggle); untouched folders start folded — folders touched by the plan
       and their ancestors stay open; drafted paths carry +n −n line counts
zm/zr/zM/zR  fold by level: one level closed/opened, or everything
H      toggle the related-only filter: planned paths and restriction-plain
       marks with their connecting ancestors (a [RELATED] chip marks it)
V      show/hide the agent SESSION stream pane under the tree — the live
       steps, tool calls, and retries of the running agent session
Tab    switch pane (also <Right>; <Left> returns to the tree)
Esc    cancel the running operation
Q      quit (cancels, closes the panel, shuts the host down)
```

Every operation key is also reachable globally as `<prefix><key>` with the
key identical to the TUI (`<leader>nd`, `<leader>n1`–`n9`, `<leader>n<CR>`,
… — or any prefix you prefer): `require("neolit").key(key)` opens the panel
when closed and then acts, so the maps work from any buffer. Motion and
folding keys stay pane-local. For plugin managers without lazy key specs,
set `keymap_prefix = "<leader>n"` and the plugin binds them itself.

Prompts (`N`, `Enter`, `O`, `S`) go through `vim.ui.input`, so
`dressing.nvim`/`snacks.nvim` style pickers work if installed.

## Configuration

```lua
require("neolit").setup({
  neolit_dir = nil,     -- path to a neolit checkout with dist/ (default: $NEOLIT_DIR,
                        -- then ../neolit beside this plugin, then npm root -g)
  node = "node",        -- Node executable for the host shim
  directory = nil,      -- repository root; default: working directory at open
  no_model = false,     -- force NO MODEL mode (AUGMENT_TUI_NO_MODEL=1)
  persist_tasks = true, -- persist and resume the active task (AUGMENT_TUI_TASKS)
  sidebar_width = 42,   -- tree sidebar width in columns
  detail_width = nil,   -- diff-column width (nil = half the non-sidebar space; the description column keeps a 24-column minimum)
  palette = "system",   -- "system": follow the colorscheme via semantic links
                        -- "tui": the terminal TUI's exact hexes
  keymap_prefix = nil,  -- e.g. "<leader>n": bind every TUI operation key globally
  host_args = nil,      -- extra argv for host.mjs (advanced/tests)
  hooks = nil,          -- { input = …, select = … } test seams
})
```

The **agent socket**: while the panel is open it serves its own address,
`$XDG_RUNTIME_DIR/neolit/augment-nvim.sock` (distinct from the TUI's
`augment.sock`, so both can run at once), reported in every pushed frame's
`socketPath` field. External agents attach with
`augmentd --mcp --connect <path>` and their
mutations render live. Override with `AUGMENT_TUI_SOCKET`; disable with
`no_socket = true` or `AUGMENT_TUI_NO_SOCKET=1`.

Model configuration is shared with the TUI: `~/.config/neolit/augment.json`
(written by `augment setup`), the same `AUGMENT_*` environment variables, and
the same agent backends (OpenCode by default; `AUGMENT_BACKEND=claude|codex`).
Authentication belongs to each backend's CLI.

## Attaching an external agent

While the panel is open it serves the same agent socket the TUI does
(`AUGMENT_TUI_SOCKET` overrides the path, `AUGMENT_TUI_NO_SOCKET=1`
disables it); every pushed frame reports the address in its `socketPath`
field. Point an MCP agent
host at it:

```sh
augmentd --mcp --connect "$XDG_RUNTIME_DIR/neolit/augment.sock" --directory .
```

Every tool call (`draft_file`, `select_approach`, `refine_plan`, …) mutates
the task the panel is rendering: adopted changes repaint the sidebar and
detail panes as they land, with an "Agent update rendered" notice. A write
racing a running panel operation queues behind it and then fails the
optimistic-concurrency check, like any other stale writer.

## Architecture

```text
┌─ Neovim ─────────────────────────────┐      ┌─ node host/host.mjs ─────────┐
│ lua/neolit/ui.lua      panel splits  │      │ AugmentTuiController        │
│ lua/neolit/keys.lua    key routing   │◄────►│ CliAgentRuntime (opencode/  │
│ lua/neolit/host.lua    JSON-RPC job  │ stdio│   claude/codex)             │
│ lua/neolit/render.lua  extmarks      │ JSON │ detail.js view model        │
│ lua/neolit/{theme,config,framing}    │      │ apply/commit transactions   │
└──────────────────────────────────────┘      └─────────────────────────────┘
```

- Requests are one JSON-RPC object per line (no batches), like `augmentd`.
  Every state-changing request answers with a fresh **frame**: header chips,
  tree rows with colored segments, detail lines, panel state, and the numbered
  approach choices open on the selected row.
- Host callbacks are routed by owning session: a previous panel's
  shutting-down host still pushes frames, and they can never paint — or
  error-close — a newer panel.
- Long operations never block: `frame` requests carry the animated spinner
  while an operation runs; the shim pushes `neolit/progress` and `neolit/frame`
  notifications when a background follow-up (the automatic approach generation
  after a task starts) begins or completes, and when an external agent's
  mutation over the socket lands while the panel is idle.
- The automatic singleton adoption, develop policy, restriction plain
  semantics, apply preflight, and pathspec commit all live in the controller
  and kernel — nothing is duplicated in Lua.
- `lua/neolit/theme.lua` maps the TUI palette onto `Neolit*` highlight groups
  (defined with `default = true`, so a user highlight wins); override any
  `Neolit*` group to restyle.

Known divergences from the TUI: `M` lists the backend's model catalog when
available and falls back to typing a model id; the input line is
`vim.ui.input` instead of the embedded panel input; status lives in the
winbar and feedback in `vim.notify` instead of the TUI's header and message
panel.

## Validation

```sh
npm test                        # host shim end-to-end over stdio (node --test)
nvim --clean -l test/run.lua    # Lua units + full-stack headless UI smoke test
```

The tests need a built neolit `dist/` next to this plugin (or `NEOLIT_DIR` /
`NEOLIT_TEST_DIST`). The Lua suite runs the real UI against the shim's
deterministic stub model runtime inside a throwaway git fixture; nothing
touches your repositories or persisted tasks (`AUGMENT_TUI_TASKS=0`).
