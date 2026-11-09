# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), a Git-native
planning workspace with an explicit tree-only planning-entry delete action.

Neolit parses linked README/SPEC/TODO documents and relates TODO tasks,
SPEC requirements, acceptance criteria, planned files, and current Git changes.
It does not own an agent runtime or persist conversation history, and it does not modify the Git index or history. The explicit tree delete action edits only the selected Markdown entry in the worktree.

## Requirements

- Neovim 0.10+
- Node.js 22.12+
- A built Neolit checkout containing `dist/index.js` and `dist/planning/`

Build the core:

```sh
cd /path/to/neolit
npm install
npm run build
```

Install:

```lua
{
  "1suo/neolit.nvim",
  opts = {
    neolit_dir = "/path/to/neolit",
    -- directory = "/path/to/repository", -- defaults to cwd
    -- comparison_base = "HEAD",
    -- diff_view = "side_by_side", -- or "unified"
    -- keymaps = { open_workspace = "<leader>nn" },
    -- opencode = { url = "http://127.0.0.1:4096" },
    -- agent = { send = function(request) ... end }, -- optional override
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
```

## Agent session binding

Agent sessions are associated with the canonical worktree path and stored in
Neovim's state directory, independently for each worktree. The binding stores
only the host session ID and display label; it does not store transcripts or
messages.

- `:NeolitAgentBind <session-id> [label]` binds an existing host session to
  the configured worktree (or the current working directory).
- `:NeolitAgentSession` displays the current binding.
- `:NeolitAgentUnbind` removes it.

The composed view opens an editable floating message draft (`<leader>nm`)
containing the selected, revalidated context. Neolit uses the OpenCode HTTP
server by default and sends to the exact bound session ID; the conversation
remains in OpenCode's session store. Responses are displayed when the request
finishes (the HTTP adapter does not yet stream tokens).

Expose the OpenCode server on a stable local port when starting the TUI:

```sh
opencode --hostname 127.0.0.1 --port 4096
```

Alternatively, run `opencode serve --hostname 127.0.0.1 --port 4096`.
Set `opts.opencode.url` if it listens elsewhere. The adapter verifies the
session ID and, when the server reports it, checks that its directory matches
the selected worktree before sending. It uses the existing session's agent and
model; it does not create a session or start a second agent runtime. `curl`
must be available.

An optional `opts.agent.send(request)` function overrides the built-in
transport. The request contains `session_id`, `worktree`, `message`,
`on_chunk`, `on_done`, and `on_error`.

## Workspace

`:Neolit` or `<leader>nn` opens one compact repository tree and reuses the
existing right pane for real source buffers and native diffs. The tree contains
repository paths only; TODO tasks and SPEC requirements are not duplicated as
tree nodes. The tree header summarizes task, requirement, changed-file, and
unplanned-path counts; its navigation column stays 36 columns wide while the
preview uses the remaining space. Wrapping follows Neovim's global `wrap`.

Opening a TODO or SPEC file keeps the actual editable Markdown buffer and adds
derived annotations beside source entries. Changed files expand to show
candidate task links and hunk attribution. File-path hints never prove
implementation; selecting a hunk opens that exact native diff.

The composed view connects SPEC requirements, TODO tasks, acceptance criteria,
file hints, and observed Git changes. `za` expands semantic entries and scope
sections; `<CR>` opens the selected source or diff. Literal source chunks,
file diffs, and exact hunks can be added to context, reviewed, removed, and
revalidated before copying or opening the message draft. Source Markdown
remains authoritative.

Neolit actions use semantic mappings under `<leader>n` by default. Override
individual actions with `opts.keymaps`; set an action to `false` to disable it.
Native navigation and fold mappings remain native (`j`/`k`, `h`/`l`, `za`,
`zo`, `zc`, `zr`, `zm`, `zR`, `zM`). Neolit does not install its action maps in
ordinary source-file buffers.

## Default actions

| Mapping | Action |
| --- | --- |
| `<leader>nn` | Open workspace |
| `<leader>nv` | Open composed requirement/task view |\n| `<leader>n<CR>` | Open selected tree entry / diff |
| `<leader>ns` | Open selected task scope |
| `<leader>na` / `<leader>nd` | Add / remove context |
| `<leader>np` | Review context |
| `<leader>ny` | Copy validated context |
| `<leader>nc` | Clear context |
| `<leader>nm` | Open floating message draft |\n| `<leader>no` | Open selected source from composed views |
| `<leader>ne` / `<leader>no` | Edit diff side / open actual file |
| `<leader>nD` | Delete selected planning entry |
| `<leader>nx` / `<leader>nl` | Copy selected text / source path |
| `<leader>nf` | Toggle affected-only paths |
| `<leader>nr` | Refresh |
| `<leader>nd` | Toggle diff layout |
| `<leader>nq` | Close workspace |

`Description:` explains task intent; `Agent notes:` explains actual changes,
rationale, deviations, or caveats. Notes are not verification evidence.

Derived states come from parsed planning documents and current Git metadata;
verification requires matching evidence for the current base commit and diff.
