# neolit.nvim

Neovim companion for [Neolit](https://github.com/1suo/neolit), a Git-native planning workspace. It connects TODO/SPEC documents to current Git changes and composes exact source and diff context for an existing coding-agent chat.

Neolit is not an agent runtime or a diff-review UI. Markdown remains the planning source of truth; Git remains the source of truth for code changes. CodeCompanion owns chat, agent sessions, diff presentation, and review.

## Requirements

- Neovim 0.10+
- Node.js 22.12+
- Node.js 22.12+ and npm (the core is installed automatically by the plugin build step)

## Install and configure

Example for lazy.nvim:

~~~lua
{
  "1suo/neolit.nvim",
  build = "npm install", -- installs/builds the core dependency automatically
  dependencies = {
    {
      "olimorris/codecompanion.nvim",
      dependencies = { "nvim-lua/plenary.nvim", "nvim-treesitter/nvim-treesitter" },
      opts = {
        interactions = {
          chat = { adapter = "opencode" }, -- starts OpenCode through ACP
        },
      },
    },
  },
  opts = {
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
  keys = {
    { "<leader>nn", "<cmd>Neolit<cr>", desc = "Open Neolit workspace" },
  },
  cmd = { "Neolit", "NeolitPlan", "NeolitClose" },
}
~~~

Call require("neolit").setup(opts) if your plugin manager does not pass opts automatically.

### Core discovery

The lazy.nvim build step installs the core directly into the plugin. No global npm install, separate checkout, or core path configuration is required.

### CodeCompanion

The dependency above installs **and configures** CodeCompanion. Merely listing it as a dependency is not enough: lazy.nvim only runs its setup when it has `opts` (or an explicit `config` function). Without setup, commands such as `:CodeCompanionChat` do not exist.

This setup selects OpenCode's built-in ACP adapter. It requires the `opencode` executable on your PATH and a working OpenCode login/configuration. If you already configure CodeCompanion elsewhere, keep that setup and merge the `interactions.chat.adapter = "opencode"` setting into it.

- <leader>nm opens a CodeCompanion chat using the configured adapter.
- Use CodeCompanion's /resume command in chat to resume an existing OpenCode session.
- <leader>nM adds the current Neolit context composition to the active CodeCompanion chat.
- <leader>nF adds the selected file as a quoted Markdown link, without attaching its contents.
- <leader>ne invokes CodeCompanion Code Review.
- <leader>nC invokes CodeCompanion's agent Changes list.

The Changes list reflects CodeCompanion tool/ACP edits observed during the current Neovim session. Neolit's Git view independently discovers repository changes, including changes made by external CLI runs.

## Usage

Open Neolit from the repository you want to inspect:

- :Neolit
- :NeolitPlan
- Default shortcut: <leader>nn

The workspace opens a 36-column tree on the left and reuses the current window as the source preview on the right. Reopening Neolit focuses the existing workspace. :NeolitClose or `q` closes it.

### Commands

Workspace commands are buffer-local while the Neolit tree is open (and `:NeolitChatFile` is also available in composed views): `:NeolitCompose`, `:NeolitOpen`, `:NeolitOpenFile`, `:NeolitFilter`, `:NeolitRefresh`, `:NeolitDelete`, `:NeolitCopyText`, `:NeolitCopyPath`, `:NeolitToggle`, `:NeolitChat`, `:NeolitChatFile`, `:NeolitAgentChanges`, and `:NeolitReview`.

Composed views also expose `:NeolitContextAdd`, `:NeolitContextRemove`, `:NeolitContextCopy`, `:NeolitContextClear`, `:NeolitContextReview`, and `:NeolitChatContext`. These commands act on the current Neolit selection; they are not global commands.

### Navigate and inspect

- Expand/collapse folders, planning files, and changed files with za, zo, and zc.
- zr / zm open or close one visible level; zR / zM expand or collapse all.
- <CR> opens the selected source or expands the selected tree node.
- `o` opens the selected file in the right pane; `F` toggles the selected tree node; `h` / `l` collapse/expand or move to the parent.
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
| tree_open_selected | <CR> |
| tree_toggle | F |
| tree_expand_node | l |
| tree_collapse_node | h |
| tree_open_file | o |
| task_scope | <leader>ns |
| context_add | <leader>na |
| context_remove | <leader>n- |
| context_review | <leader>np |
| context_copy | <leader>ny |
| context_clear | <leader>nc |
| chat_open | <leader>nm |
| chat_context | <leader>nM |
| chat_file | <leader>nF |
| review_changes | <leader>ne |
| agent_changes | <leader>nC |
| affected_filter | <leader>nf |
| delete_entry | <leader>nD |
| copy_text | <leader>nx |
| copy_path | <leader>nl |
| tree_fold_toggle | za |
| tree_fold_close | zc |
| tree_fold_open | zo |
| tree_expand_level | zr |
| tree_collapse_level | zm |
| tree_expand_all | zR |
| tree_collapse_all | zM |
| refresh | <leader>nr |
| close_workspace | q |
| view_help | ? |

Override by action name. For example, this restores short tree-local actions while keeping native Neovim keys unchanged elsewhere:

~~~lua
keymaps = {
  tree_toggle = "F",
  tree_expand_node = "l",
  tree_collapse_node = "h",
  tree_open_file = "o",
  close_workspace = "q",
  delete_entry = "d",
  refresh = "r",
  chat_file = "<leader>nF",
  context_add = "<leader>pa",
  context_copy = "<leader>py",
}
~~~

Workspace entry, CodeCompanion chat, review, agent changes, and current-file linking are global mappings. Tree navigation/filter/refresh/delete/copy actions are tree-local; task/context actions are available only in the composed views where their selection makes sense. No Neolit mappings are installed in ordinary source-file buffers. Native movement and fold keys remain available.
