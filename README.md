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

    -- Markdown capture destinations (relative planning paths are repo-relative).
    journal_dir = "~/Documents/memo/journal",
    todo_file = "TODO.md",
    spec_file = "SPEC.md",

    -- CodeCompanion adapter used by <leader>nm.
    codecompanion = { adapter = "opencode" },

    -- Keep the tree compact by default. Alternatives: "hunks", "codecompanion".
    change_view = "files",

    -- Window destinations: tree = "left" | "current";
    -- file/diff = "right" | "tree" | "current"; chat = "right" | "current" (split origin).
    layout = {
      tree = "left",
      width = 36,
      file = "right",
      diff = "right",
      chat = "right",
    },

    -- Neolit installs no keymaps unless you define them here.
    keymaps = {
      open_workspace = "<leader>nn",
      chat_open = "<leader>nm",
      review_changes = "<leader>ne",
      agent_changes = "<leader>nC",
      chat_file = "<leader>nF",
      context_yank = "<leader>nY",
      tree_open_selected = "<CR>",
      tree_open_file = "o",
      tree_toggle = "F",
      tree_expand_node = "l",
      tree_collapse_node = "h",
      close_workspace = "q",
      tree_help = "?",
      open_journal = "<leader>nJ",
      capture_journal = "<leader>nj",
      capture_task = "<leader>nt",
      capture_requirement = "<leader>nR",
      capture_criterion = "<leader>nA",
    },
  },
  cmd = {
    "Neolit", "NeolitPlan", "NeolitClose", "NeolitJournal",
    "NeolitCaptureJournal", "NeolitCaptureTask",
    "NeolitCaptureRequirement", "NeolitCaptureCriterion",
  },
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
- <leader>nM yanks the current Neolit context composition to the unnamed register and clipboard; paste it into the agent chat. No temporary buffer is created or switched into CodeCompanion.
- <leader>nF yanks the selected file as a quoted Markdown link; no scratch buffer is created and no file contents are attached.
- <leader>nY yanks formatted context for the selected task, requirement, file diff, or exact hunk.
- <leader>ne invokes CodeCompanion Code Review.
- <leader>nC invokes CodeCompanion's agent Changes list.

The Changes list reflects CodeCompanion tool/ACP edits observed during the current Neovim session. Neolit's Git view independently discovers repository changes, including changes made by external CLI runs.

## Usage

Open Neolit from the repository you want to inspect:

- :Neolit
- :NeolitPlan
- Optional shortcut: configure `keymaps.open_workspace`

By default the workspace opens a 36-column tree on the left and uses the existing window on the right for file/diff previews and agent chat. Reopening Neolit restores the tree if a file/diff is configured to replace it. :NeolitClose or `q` closes it.

Set `layout.tree = "current"` to open the tree without splitting. Set `layout.file` or `layout.diff` to `"tree"` to show that content in the tree's window, or `"current"` to use the focused window. Set `layout.chat = "current"` to use the current window as CodeCompanion's split origin instead of the right-hand pane. CodeCompanion still owns the chat window geometry; Neolit places its vertical split to the right by default.

### Commands

Workspace commands are buffer-local while the Neolit tree is open (and `:NeolitChatFile` is also available in composed views): `:NeolitCompose`, `:NeolitOpen`, `:NeolitOpenFile`, `:NeolitFilter`, `:NeolitRefresh`, `:NeolitDelete`, `:NeolitCopyText`, `:NeolitCopyPath`, `:NeolitToggle`, `:NeolitChat`, `:NeolitChatFile`, `:NeolitAgentChanges`, and `:NeolitReview`.

Composed views also expose `:NeolitContextAdd`, `:NeolitContextRemove`, `:NeolitContextCopy`, `:NeolitContextClear`, `:NeolitContextReview`, and `:NeolitChatContext`. These commands act on the current Neolit selection; they are not global commands.

### Capture and journal

- `<leader>nj` opens a short journal capture; `<leader>nJ` opens the current monthly journal file.
- `<leader>nt` captures a checkbox task into the configured TODO file.
- `<leader>nR` captures the next `R-NN` requirement; `<leader>nA` captures the next `AC-NN` acceptance criterion.
- Capture buffers save with `Ctrl-S` (or `:write`) and cancel with `Ctrl-C`.
- Journal files are monthly Markdown files with daily headings and timestamped entries. Tasks and specifications are inserted under `## Tasks`, `## Requirements`, and `## Acceptance criteria` respectively.
- Commands: `:NeolitJournal`, `:NeolitCaptureJournal`, `:NeolitCaptureTask`, `:NeolitCaptureRequirement`, and `:NeolitCaptureCriterion`.

Captured tasks still need explicit `SPEC:` references to participate in requirement traceability. Acceptance criteria should name their applicable `R-NN` IDs. The configured TODO and SPEC files are loaded even when they are not linked from README; additional linked planning documents continue to be discovered normally.

### Navigate and inspect

- Expand/collapse folders, planning files, and changed files with za, zo, and zc.
- `change_view = "files"` keeps changed-file rows compact. Use `"hunks"` to show Neolit's Git hunk attribution, or `"codecompanion"` to opt into CodeCompanion's grouped review checklist. The CodeCompanion checklist is not built in the default file view.
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

Neolit installs **no keymaps by default**. All mappings are opt-in through the `keymaps` table in your plugin configuration. Omit an action to leave its keys untouched; set it to `false` or `""` to disable it explicitly. Commands remain available without mappings.

Keymap action names include:

- Global: `open_workspace`, `chat_open`, `agent_changes`, `review_changes`, `chat_file`, `open_journal`, `capture_journal`, `capture_task`, `capture_requirement`, `capture_criterion`.
- Tree: `context_yank` yanks a formatted reference/diff for the selected row.
- Tree: `tree_open_selected`, `tree_open_file`, `tree_toggle`, `tree_expand_node`, `tree_collapse_node`, `tree_composed`, `task_scope`, `affected_filter`, `refresh`, `delete_entry`, `copy_text`, `copy_path`, `close_workspace`, `tree_help`, and `tree_fold_toggle`, `tree_fold_open`, `tree_fold_close`, `tree_expand_level`, `tree_collapse_level`, `tree_expand_all`, `tree_collapse_all`.
- Composed/context views: `open_source`, `view_back`, `view_help`, `context_add`, `context_remove`, `context_copy`, `context_clear`, `context_review`, `chat_context`, `switch_projection`, `copy_source`, `copy_path`.

Mappings are installed only in their relevant scope: global actions anywhere, tree actions in the tree, and context/task actions in the views that support them. Native Neovim keys are not overridden unless you explicitly assign them.
