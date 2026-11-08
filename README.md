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
    -- diff_view = "side_by_side",       -- or "unified"; toggle at runtime with D
    -- node = "node",
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
```

## Commands and workflow

- `:Neolit` or `:NeolitPlan` opens the read-only diff-first workspace. The primary section is an expandable file → hunk → changed-line tree; added and removed lines are individually selectable, while task and requirement traceability follows below it.
- `za` expands/collapses the selected changed file, `zR` expands all files, and `zM` collapses all files. Expanded hunks list added (`+`) and removed (`-`) lines in Git patch order. `K` opens a focused details window for the selected file, hunk, changed line, task, or requirement; long rationale and candidate lists stay out of the tree. Task details include resolved SPEC requirements, acceptance criteria, and unresolved references; requirement details also list linked TODO tasks and their derived states. Task questions also include bounded excerpts from the most relevant linked README documents, selected by the shared core. Selecting a task or requirement highlights its known linked rows in the diff tree and traceability section.
- `<CR>` on a TODO task or SPEC requirement opens its exact Markdown source.
- `<CR>` on a planned file opens the file, or its actual Git diff once changed.
- `<CR>` on a changed file/hunk opens a native side-by-side diff against the
  selected comparison base; on an individual added/removed line it opens at
  that exact line on the working-tree/base side respectively.
- `x` on a task, requirement, file, hunk, or individual changed line asks for a question and copies a
  bounded context packet for the user's existing agent conversation. Task/requirement packets include resolved linked SPEC text and acceptance criteria; line packets carry the exact side and line coordinate.
- In a native diff, `<leader>nx` on a line or visual selection copies context
  for those exact lines. Stale diff/base anchors are rejected.
- `D` toggles side-by-side and unified diff presentation. `r` refreshes; the workspace also refreshes after writes, on focus return, and while idle so external agent edits are picked up. `q`, `<Esc>`, or `:NeolitClose` closes the workspace.

The diff tree displays every changed file and its hunks first, with Git status,
conservative mapping markers, and exact candidate task/requirement references
on each hunk row. TODO/SPEC traceability, derived task/requirement states,
and planned-file annotations remain available in the sections below.
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
  diff_view = "side_by_side", -- or "unified"; toggle at runtime with D
})
```

The core reads repository documents and Git metadata only. It does not execute
repository scripts or alter the worktree, index, or history.
