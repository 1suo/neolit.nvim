# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), a Git-native planning workspace. It connects TODO/SPEC documents to current Git changes and composes exact source and diff context for an existing coding-agent chat.

Neolit is not an agent runtime or a diff-review UI. Markdown remains the planning source of truth; Git remains the source of truth for code changes. CodeCompanion owns chat, agent sessions, diff presentation, and review.

## Requirements

- Neovim 0.10+
- Node.js 22.12+
- A built Neolit core checkout containing dist/index.js and dist/planning/workspace.js

Build the core:

~~~sh
git clone https://github.com/1suo/neolit.git
cd neolit
npm install
npm run build
~~~

## Install and configure

Example for lazy.nvim:

~~~lua
{
  "1suo/neolit.nvim",
  dependencies = {
    "olimorris/codecompanion.nvim", -- optional; required for agent chat/review
  },
  opts = {
    -- Path to the built core checkout.
    neolit_dir = vim.fn.expand("~/Projects/neolit"),

    -- Repository to inspect; defaults to the current working directory.
    -- directory = vim.fn.getcwd(),

    comparison_base = "HEAD",
    node = "node",

    -- CodeCompanion adapter used by <leader>nm.
    codecompanion = { adapter = "opencode" },

    -- Override individual Neolit normal-mode mappings.
    keymaps = {
      open_workspace = "<leader>nn",
      review_changes = "<leader>ne",
      agent_changes = "<leader>nC",
      -- Set an action to false to disable its mapping.
      -- context_add = false,
    },
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
~~~

Call require("neolit").setup(opts) if your plugin manager does not pass opts automatically.

### Core discovery

Neolit looks for the built core in this order:

1. opts.neolit_dir
2. $NEOLIT_DIR
3. A sibling ../neolit checkout next to the plugin
4. The global npm root's neolit directory

Set neolit_dir or NEOLIT_DIR if your checkout is elsewhere. Neolit does not build the core automatically.

### CodeCompanion

CodeCompanion is optional for browsing and planning. Install and configure CodeCompanion with an adapter you use; the default Neolit adapter name is opencode. OpenCode is accessed through CodeCompanion's ACP integration, not a Neolit-owned transport.

- <leader>nm opens a CodeCompanion chat using the configured adapter.
- Use CodeCompanion's /resume command in chat to resume an existing OpenCode session.
- <leader>nM adds the current Neolit context composition to the active CodeCompanion chat.
- <leader>ne invokes CodeCompanion Code Review.
- <leader>nC invokes CodeCompanion's agent Changes list.

The Changes list reflects CodeCompanion tool/ACP edits observed during the current Neovim session. Neolit's Git view independently discovers repository changes, including changes made by external CLI runs.

## Usage

Open Neolit from the repository you want to inspect:

- :Neolit
- :NeolitPlan
- Default shortcut: <leader>nn

The workspace opens a 36-column tree on the left and reuses the current window as the source preview on the right. Reopening Neolit focuses the existing workspace. :NeolitClose or <leader>nq closes it.

### Navigate and inspect

- Expand/collapse folders, planning files, and changed files with za, zo, and zc.
- zr / zm open or close one visible level; zR / zM expand or collapse all.
- <CR> opens the selected source or expands the selected tree node.
- <leader>no opens the selected file in the right pane.
- <leader>nv opens the composed task/requirement view. From a TODO file it starts with tasks; from a SPEC file it starts with requirements.
- <leader>ns opens the selected task's focused scope.
- In composed views, za expands/collapses the selected task or requirement, and <leader>nv switches task/requirement projection.
- <leader>nf toggles between all repository paths and affected-only paths.
- <leader>nr refreshes the workspace.
- <leader>n? displays view-specific key hints.

Opening TODO/SPEC files shows derived annotations beside the real Markdown source. Composed views connect requirements, tasks, acceptance criteria, file hints, and observed Git changes. File hints are relevance signals, not proof that a task is implemented. Verification is based on evidence associated with the current base and diff.

### Compose context for an agent

Context composition is temporary and literal: it collects selected source excerpts, planning entries, changed-file diffs, or exact hunks. It does not generate a prompt or send a message by itself.

- <leader>na adds the selected source chunk or change/hunk to the context.
- <leader>np opens the context review view.
- In the context view, <leader>n- removes the selected item; <leader>ny copies the assembled context; <leader>nc clears it.
- <leader>ny also copies the assembled context from composed views.
- <leader>nM adds the composed context to the active CodeCompanion chat.
- <leader>nx copies selected text; <leader>nl copies the selected source path (and line, when available).

Before copy or chat insertion, Neolit revalidates captured source ranges and diffs. Stale content and modified, unsaved planning buffers are not silently substituted.

### Review changes

Neolit supplies Git-wide changed-file discovery, affected-only filtering, and task/requirement/hunk attribution. Selecting a changed file or hunk navigates to its working-tree source.

Use CodeCompanion for diff presentation and review actions:

- <leader>ne — CodeCompanion Code Review
- <leader>nC — CodeCompanion agent Changes list

Neolit does not stage, reset, checkout, apply, commit, or rewrite Git history. Its explicit planning-entry delete action is separate from Git operations.

### Delete a planning entry

In the tree or a composed view, select a TODO task, SPEC requirement, or acceptance criterion and press <leader>nD. The selected Markdown entry is removed from its source file. This action rejects unsafe paths and modified source buffers; write the buffer first. There is no delete mapping in ordinary preview buffers.

### Task fields

- **Description** states the task's intent and desired outcome.
- **Agent notes** summarize actual implementation, rationale, deviations, or caveats. They are not verification evidence.

## Configuration reference

| Option | Default | Purpose |
| --- | --- | --- |
| neolit_dir | nil | Path to the built Neolit core checkout |
| node | "node" | Node.js executable |
| directory | current working directory | Repository to inspect |
| comparison_base | "HEAD" | Git base for change discovery |
| codecompanion.adapter | "opencode" | CodeCompanion adapter for <leader>nm |
| keymaps | see below | Per-action normal-mode mapping overrides |

Default keymaps:

| Action | Default |
| --- | --- |
| open_workspace | <leader>nn |
| tree_composed | <leader>nv |
| tree_open_selected | <leader>n<CR> |
| tree_open_file | <leader>no |
| task_scope | <leader>ns |
| context_add | <leader>na |
| context_remove | <leader>n- |
| context_review | <leader>np |
| context_copy | <leader>ny |
| context_clear | <leader>nc |
| chat_open | <leader>nm |
| chat_context | <leader>nM |
| review_changes | <leader>ne |
| agent_changes | <leader>nC |
| affected_filter | <leader>nf |
| delete_entry | <leader>nD |
| copy_text | <leader>nx |
| copy_path | <leader>nl |
| refresh | <leader>nr |
| close_workspace | <leader>nq |
| view_help | <leader>n? |

Override by action name:

~~~lua
keymaps = {
  open_workspace = "<leader>p",
  context_add = "<leader>pa",
  context_copy = "<leader>py",
  delete_entry = false,
}
~~~

Neolit's action mappings are buffer-local to its workspace/views. It does not install these mappings in ordinary source-file buffers. Native movement and fold keys remain available.
