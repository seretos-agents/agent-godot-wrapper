# agent-godot-wrapper

A Claude Code **skill** plugin. Pairs the external [Godot MCP Toolkit](https://github.com/NPGameDev/godot-mcp-toolkit) bridge with a skill so Claude can drive the Godot 4 editor — inspecting scenes, nodes, scripts and resources, running playtests — through structured MCP operations instead of guessing project state.

This plugin ships **only skill content** — no binaries of its own. It wraps a separate, pre-existing **Godot MCP server**: the npm bridge [`@npgamedev/godot-mcp-server`](https://github.com/NPGameDev/godot-mcp-server) is declared inline in both plugin manifests and launched automatically via `npx`, pinned to an exact version (`@npgamedev/godot-mcp-server@1.0.4`) so `npx` resolves the same cached package on every start. It is the Godot counterpart of [`agent-unity-wrapper`](https://github.com/seretos-agents/agent-unity-wrapper).

> **Status:** wired. The bridge is connected under the `godotMCP` server key and `skills/godot-wrapper/SKILL.md` ships the full tool inventory and usage docs. See `AGENTS.md` for the contracts an agent won't infer from the tree.

## Prerequisites

### 1. Node.js 22+

`npx` (bundled with npm) launches the bridge on demand without a global install. Run `node --version` to check.

### 2. Godot 4.2+ with the Godot MCP Toolkit addon

The bridge is only half of the MCP. The other half is an **editor addon** that runs inside the target Godot project and opens a localhost WebSocket the bridge dials:

1. In the Godot editor open the **AssetLib** tab, search "Godot MCP Toolkit", Download, Install (or extract a [GitHub release](https://github.com/NPGameDev/godot-mcp-toolkit/releases) into the project's `addons/` directory).
2. Project Settings → Plugins → **Godot MCP Toolkit** → check **Active**.
3. The Output log prints `[MCPServer] listening on 127.0.0.1:6550` (any port from 6550 to 6560) and the MCP dock appears in the bottom panel.

Godot 4.5+ is recommended; C# projects need the mono (.NET) editor build. Commit the addon to the game repo — its export plugin strips it from shipped builds.

**Do not also keep a `godot-mcp-toolkit` entry in the project's own `.mcp.json`** (the one the addon's dock offers to write). This plugin already launches the bridge; a second entry would start a second bridge against the same editor.

## Install

```
/plugin marketplace add seretos-agents/modular-software-factory
/plugin install agent-godot-wrapper@modular-software-factory
```

Start Claude Code from the Godot project root (or a linked worktree of it) with the editor open on that same project. The bridge finds the editor through the toolkit's machine-wide registry, keyed by project path — no port or token to configure.

Optional: to let `agent-worktree` boot a per-checkout editor (`environment_start`), run `pwsh scripts/prepare-godot-worktree.ps1` from this plugin once at your Godot repo root and commit the result; set `GODOT_EDITOR_PATH` to your editor binary (or put `godot` on `PATH`). See `skills/godot-wrapper/SKILL.md`.

## What the skill teaches

- **`godot-wrapper`** — drives the Godot editor through the toolkit: scene tree and node CRUD, properties and signals, scripts with inline diagnostics, resources, project settings and autoloads, the playtest loop (`game_start`, live node inspection, input simulation, screenshots, game log, `game_stop`), on-demand tool groups via `discover_tools`, worktree and headless (`godot --headless --editor`) setups, and recovery when a tool call cannot reach the editor. See `skills/godot-wrapper/SKILL.md`.

## Troubleshooting

**Every tool fails with a connection error.** The editor is not open on this project, the addon is not active, or the session was started from a directory that is not the project root. Open the project, confirm the `[MCPServer] listening` line, then retry; if it still fails, reconnect the MCP server (`/mcp` → reconnect).

**Only read-style tools are visible.** Read-only mode is on (`GODOT_MCP_READ_ONLY=1`, or the dock's toggle). Turn it off and reconnect — the tool list is decided at connect time.

**"Server not loaded" right after install.** Cold `npx` start: the package downloads before the first JSON-RPC byte, which can exceed the host's handshake timeout. Reconnect the MCP server — it starts cleanly once npm has cached it. To warm the cache ahead of time (this also needs no editor):

```
npx -y @npgamedev/godot-mcp-server@1.0.4 --tools-count
```

**Windows: `spawn npx ENOENT` / `EINVAL`.** `npx` is a `.cmd` shim on Windows and older MCP hosts cannot start it directly. Update Claude Code; current versions start it.

**npm says "could not determine executable to run".** A stale `npx` cache entry. Delete the `_npx` folder inside `npm config get cache` and retry.

Do not otherwise run the bridge manually — the host owns that process.
