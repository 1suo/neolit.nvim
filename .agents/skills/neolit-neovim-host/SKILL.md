---
name: neolit-neovim-host
description: Use when changing the Neolit Neovim plugin, Lua UI, keymaps, or Node host shim.
---

# Neolit Neovim host workflow

The plugin is a thin Neovim surface over the shared Neolit controller. Its
source of plan truth is the `1suo/neolit` package, not Lua state.

## Before editing

Read this repository's `AGENTS.md` and `README.md`. For behavior owned by the
controller, also read the core repository's `AGENTS.md`,
`.agents/skills/neolit-planned-diff-workflow/SKILL.md`, `src/augment/SPEC.md`,
and `src/tui/README.md`.

## Ownership rules

- `host/host.mjs`: embeds the built controller/detail renderer and maps RPC
  actions to controller methods.
- `lua/neolit/ui.lua`: creates windows, renders host frames, and dispatches
  user actions.
- `lua/neolit/keys.lua`: describes and maps public actions.
- `lua/neolit/init.lua`: public setup and global key entrypoints.
- `README.md`: user-facing installation, layout, keymap, and configuration.

Never reproduce plan reducers, model routing, agent session handling, watcher
logic, path indexing, overlays, patch application, verification, or commit
rules in Lua. Add an RPC action to the host shim and a matching UI/key action
instead.

## Adding an action

1. Confirm the controller method exists in the shared `neolit` package.
2. Add a host method in `host/host.mjs` that calls that controller method and
   returns the normal frame response.
3. Add an operation label and dispatch method in `lua/neolit/ui.lua`.
4. Add the public key description and global action in `lua/neolit/keys.lua`.
5. Update `lua/neolit/init.lua` key documentation and the README key table.
6. Keep the action consistent with the standalone TUI key contract.
7. Verify the package path points at a build of the current core checkout
   before manual acceptance; a stale `dist/` makes the host appear unchanged.

## Handoff

Report exact files/commits and whether the build and manual `:Neolit` smoke
check were actually performed. Do not claim tests or runtime checks that were
not run.
