# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), the
Git-native planning and diff-traceability core.

The plugin is deliberately thin: it loads the shared TypeScript core, renders
ordinary README/SPEC/TODO intent beside actual Git changes, and uses native
Neovim buffers and diff windows. It does not generate or apply patches, stage
or commit files, run an agent, or maintain a separate task/session store.

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

Install the plugin:

```lua
{
  "1suo/neolit.nvim",
  opts = {
    neolit_dir = "/path/to/neolit",
    -- directory = "/path/to/repository", -- defaults to current working directory
    -- comparison_base = "HEAD",          -- any commit/ref; defaults to HEAD
    -- node = "node",
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
```

## Commands and workflow

- `:Neolit` or `:NeolitPlan` opens the read-only planning workspace.
- `<CR>` on a TODO task or SPEC requirement opens its exact Markdown source.
- `<CR>` on a planned file opens the file, or its actual Git diff once changed.
- `<CR>` on a changed file/hunk opens a native side-by-side diff against the
  selected comparison base.
- `x` on a task, requirement, file, or hunk asks for a question and copies a
  bounded context packet for the user's existing agent conversation.
- In a native diff, `<leader>nx` on a line or visual selection copies context
  for those exact lines. Stale diff/base anchors are rejected.
- `r` refreshes; `q` or `:NeolitClose` closes the workspace.

The view displays TODO/SPEC traceability, derived task/requirement states,
planned-file annotations, Git status, per-hunk mapping uncertainty, and exact
candidate task/requirement references on each hunk row.
File hints are candidates, not proof of implementation. README/SPEC/TODO
files remain untouched; TODO checkboxes are not verification evidence.

The context action uses the editor clipboard (with the unnamed register as a
fallback). It never sends source text to an agent or creates a Neolit-owned
conversation. Paste the packet into the intended existing session yourself.

## Configuration

```lua
require("neolit").setup({
  neolit_dir = "/path/to/neolit", -- or $NEOLIT_DIR / sibling checkout / npm global root
  node = "node",
  directory = nil,                -- repository root; default: cwd
  comparison_base = "HEAD",
})
```

The core reads repository documents and Git metadata only. It does not execute
repository scripts or alter the worktree, index, or history.
