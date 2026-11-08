# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), a read-only,
Git-native planning workspace.

Neolit parses linked README/SPEC/TODO documents and relates TODO tasks,
SPEC requirements, acceptance criteria, planned files, and current Git changes.
It does not own agent conversations or modify the worktree, index, or history.

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
pane for source previews and diffs. Directories and planning documents start
collapsed.

- Expand a TODO document to see parsed tasks, descriptions, linked SPEC
  requirements, acceptance criteria, current derived state, and change evidence.
- Expand a SPEC document, then a requirement, to see referencing TODO tasks,
  acceptance-criterion coverage, and related changed hunks.
- Expand a changed file to see candidate task links and each hunk's attribution
  state and reason. File markers are `?` (no task hint), `~` (candidate or
  ambiguous hint), and `D` (planning-document change). A file hint never gets
  a confirmed-mapping checkmark: source-code hunk attribution is not inferred
  from a path alone. Selecting a hunk opens that exact diff.
- Select a task or requirement to highlight its related rows. Links use resolved
  Markdown references; file-path hints and source-range hunk matches are shown
  as evidence candidates, never as proof that implementation is complete.
- `f` toggles affected-only mode. It keeps relevant TODO/SPEC source documents
  visible alongside changed paths.
- `za` expands a changed file's task/hunk evidence. `<CR>` on a changed
  file or hunk opens its native diff directly. `<CR>` on a task or requirement
  opens its Markdown source. `e` focuses the editable working side; `o`
  opens the actual file without a diff.
- `D` toggles side-by-side/unified diff presentation. `r` refreshes;
  writes, focus return, and idle refreshes also pick up external agent edits.

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` | Move |
| `za` | Toggle selected directory, document, task, or requirement |
| `zo` / `zc` | Expand / collapse selected node |
| `h` / `l` | Parent / expand |
| `zr` / `zm` | Expand / collapse one visible level |
| `zR` / `zM` | Expand / collapse all |
| `f` | All paths / affected paths and related planning docs |
| `x` | Copy selected text, task, requirement, file diff, or hunk |
| `y` | Copy selected source path and line |
| `e` | Focus editable working side of selected diff |
| `o` | Open actual file without diff |
| `D` | Toggle diff layout |
| `r` | Refresh |
| `q` / `Esc` | Close workspace |
| `?` | Show key summary |

The tree is read-only. TODO checkboxes are not verification evidence.
Derived states come from parsed planning documents and current Git metadata;
verification requires matching evidence for the current base commit and diff.
