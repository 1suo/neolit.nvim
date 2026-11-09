# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), a Git-native
planning workspace with an explicit tree-only planning-entry delete action.

Neolit parses linked README/SPEC/TODO documents and relates TODO tasks,
SPEC requirements, acceptance criteria, planned files, and current Git changes.
It does not own agent conversations or modify the Git index or history. The explicit tree delete action edits only the selected Markdown entry in the worktree.

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
    -- diff_view = "side_by_side", -- or "unified"; toggle with D
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
```

## Workspace

`:Neolit` opens one compact repository tree and reuses the existing right
pane for real source buffers and native diffs. The tree contains repository
paths only; TODO tasks and SPEC requirements are not duplicated as tree nodes.

Opening a TODO or SPEC file keeps the actual editable Markdown buffer and adds
derived annotations beside the source entries:

- TODO task lines show their derived state, linked requirement count, and
  changed-file evidence count.
- SPEC requirement lines show their derived state and number of linked tasks.
- Acceptance-criterion lines show whether they are uncovered, linked to a task,
  or have matching verification evidence.
- Markdown remains the source of truth. Annotations are virtual text; they do
  not modify file contents or replace normal Markdown/LSP behavior.

Changed files expand to show candidate task links and each hunk's attribution
state and reason. File markers are `?` (no task hint) and `~` (candidate or
ambiguous hint). File-path hints never prove implementation. Selecting a hunk
opens that exact native diff.

- `f` toggles affected-only mode, retaining relevant planning documents.
- `<CR>` on a changed file or hunk opens its native diff. `e` focuses the
  editable working side; `o` opens the actual file without a diff.
- `D` toggles side-by-side/unified diff presentation. `r` refreshes;
  writes, focus return, and idle refreshes also pick up external agent edits.
- `x` copies the selected literal text/diff/hunk; `y` copies its source path
  and line.
- `v` opens a compact composed planning view in the right pane. From a SPEC
  it shows requirements and linked tasks; from a TODO it shows tasks and their
  linked requirements. Rows summarize state and relationship counts. Details,
  criteria, notes, and changed-file evidence stay collapsed until `za` expands
  the selected requirement or task. `<CR>` navigates to the source, `x` copies
  its Markdown range, and `y` copies its source location. Use `a` to add the
  selected source chunk or diff to a temporary context packet, `d` to remove
  it, `Y` to copy the assembled packet for the existing agent, and `c` to
  clear it. A `●` marks rows already in the packet. `v` switches between
  requirement/task projections; `?` shows the compact view's keys. Source
  ranges and diffs are checked again before copying;
  changed context is rejected rather than silently replaced. No chat/session
  is created; the packet contains only selected source chunks and diffs. The
  view is a projection; source Markdown remains editable and authoritative.

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` | Move |
| `za` | Toggle selected directory/file or composed task/requirement |
| `zo` / `zc` | Expand / collapse selected node |
| `h` / `l` | Parent / expand |
| `zr` / `zm` | Expand / collapse one visible level |
| `zR` / `zM` | Expand / collapse all |
| `f` | All paths / affected paths and related planning docs |
| `x` | Copy selected text, file diff, or hunk |
| `y` | Copy selected source path and line |
| `e` | Focus editable working side of selected diff |
| `o` | Open actual file without diff |
| `D` | Toggle diff layout |
| `r` | Refresh |
| `q` / `Esc` | Close workspace |
| `?` | Show key summary |

`Description:` explains task intent; `Agent notes:` explains actual changes,
rationale, deviations, or caveats. Notes are not verification evidence.

Derived states come from parsed planning documents and current Git metadata;
verification requires matching evidence for the current base commit and diff.
