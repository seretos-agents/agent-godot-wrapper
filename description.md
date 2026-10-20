# agent-godot-wrapper

Pairs the external [Godot MCP Toolkit](https://github.com/NPGameDev/godot-mcp-toolkit)
bridge with a skill so Claude can drive the Godot 4 editor — inspecting scenes,
nodes, scripts and resources, running playtests and reading the results back —
through structured MCP operations instead of guessing project state.

## Key features

- **Wraps an existing Godot MCP bridge** — no separate binary to build. The
  npm bridge `@npgamedev/godot-mcp-server` is declared inline in the plugin
  manifest and launched via `npx` on demand; the skill teaches Claude when and
  how to reach for its tools.
- **Editor-aware operations** — inspect and act on the edited scene tree,
  node properties, signals, groups, scripts, `.tres` resources, project
  settings and autoloads through structured calls instead of free-text
  guessing at `.tscn` and `.gd` files.
- **Playtest loop** — start the game, inspect live nodes, simulate input,
  capture screenshots, read the game log (also after a crash), stop the game.
- **Write, then verify** — every `.gd` write returns inline diagnostics, and
  `script_check` / `lsp_project_diagnostics` validate without running.
- **Worktree-safe by design** — the toolkit keys its registry by project path,
  so each linked worktree gets its own editor, port and token with no manual
  instance selection.
- **Headless-capable** — most tools work under `godot --headless --editor`
  for CI and unattended agent sessions.
- **Dual-host** — installs on both Claude Code and Codex from a single
  marketplace release.

## Requirements

- **Node.js 22+** on the host machine; `npx` launches the bridge on demand.
- **Godot 4.2+** (4.5+ recommended) with the **Godot MCP Toolkit** addon
  installed and enabled in the target project (AssetLib → "Godot MCP Toolkit").
- The Godot editor open on the project you want to drive.

## A good fit if you want to

- Build or modify scenes conversationally and see the result in the editor.
- Let an agent playtest a scene and report what it saw.
- Keep an agent on the structured tool surface instead of hand-editing
  serialized scene files.
