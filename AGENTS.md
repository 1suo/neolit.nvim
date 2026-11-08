# AGENTS.md

This repository is the Neovim host for the shared Neolit planned-diff
controller. Keep it a thin host; do not fork the plan kernel, model runtime,
repository watcher, path index, overlay loader, or apply/verify lifecycle.

## Canonical contracts

Before changing the plugin, read:

- `README.md` for installation, tab/window behavior, keymap, configuration, and
  package resolution.
- `host/host.mjs` for the Node host boundary and controller action dispatch.
- `lua/neolit/ui.lua` for frame rendering and operation dispatch.
- `lua/neolit/keys.lua` and `lua/neolit/init.lua` for public key contracts.
- In the `1suo/neolit` checkout, read `AGENTS.md`,
  `.agents/skills/neolit-planned-diff-workflow/SKILL.md`,
  `src/augment/SPEC.md`, and `src/tui/README.md`.

## Host invariants

- `host/host.mjs` embeds the same built controller and detail view used by the
  standalone TUI. Do not reimplement reducer or lifecycle behavior in Lua.
- Lua owns native windows, frame rendering, key routing, and user interaction.
  It sends actions to the host shim; the host invokes controller methods.
- The Neovim panel must preserve the current tab's windows, layout, and focus.
- Keep the public key set aligned with the standalone TUI. When adding an
  action, update `keys.lua`, `ui.lua`, `host/host.mjs`, `init.lua` key
  documentation, and `README.md` together.
- Patch application, verification, commit gating, task persistence, overlays,
  and repository staleness stay in the shared `neolit` package.
- Do not add a VS Code host or another editor surface unless explicitly asked.

## Change workflow

1. Identify whether the change belongs in shared `neolit` or this host. If the
   controller/kernel already owns it, implement it in `1suo/neolit` and keep
   this repository limited to the necessary host action and UI.
2. Preserve the newline-delimited JSON-RPC boundary and stable host response
   shapes.
3. Keep Lua code focused on layout, key routing, and frame rendering.
4. Update README behavior and key documentation with the implementation.
5. Follow the shared repository's validation instructions. Never claim a
   build, test, or live Neovim smoke check that was not actually performed.
6. Commit completed work with a conventional commit message and report the
   exact validation performed.
