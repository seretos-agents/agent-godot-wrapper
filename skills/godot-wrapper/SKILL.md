---
name: godot-wrapper
description: Drive the Godot 4 editor through the external Godot MCP Toolkit bridge (server key godotMCP) — inspect and edit the scene tree, nodes, properties, signals and groups, write and validate GDScript with inline diagnostics, author .tres resources and project settings, run a playtest (game_start, live node inspection, input simulation, screenshots, game log, game_stop), activate on-demand tool groups with discover_tools, and read the editor console for errors, instead of guessing at .tscn and .gd files. Also covers running one editor per git worktree, headless editors (godot --headless --editor) for CI and unattended sessions, and recovering when a tool call cannot reach the editor. Use when working inside a Godot project, starting or connecting to a Godot editor, when a Godot MCP tool call fails, or for requests like "build this scene", "add a node", "playtest it", "Szene bauen", "Node hinzufügen", "Spiel testen".
---

# godot-wrapper

## What this skill is for

Reach for this skill when the task involves a **Godot 4 project** — exploring or editing
its scene tree, locating nodes and their properties, writing or fixing scripts, authoring
resources, or playtesting a scene and reading back what happened. The skill routes that
work through the Godot MCP Toolkit's structured tools rather than reading or guessing at
serialized `.tscn` / `.tres` / `.gd` files.

Plain text edits to a `.gd` file the user handed you are still fine with the host's own
file tools — but prefer `script_write` / `script_edit` when the editor is up, because they
return **inline diagnostics** and keep the editor's undo history and re-indexing intact.

## Mental model

The Godot MCP has two halves that must both be running for any tool call to succeed:

1. **npm bridge** (`@npgamedev/godot-mcp-server@1.0.4`, launched via `npx`) — the process
   the MCP host (Claude Code / Codex) connects to over `stdio`. It translates MCP tool
   calls into JSON-RPC over a local WebSocket.

2. **Editor addon** (`addons/godot_mcp_toolkit/`, "Godot MCP Toolkit") — a GDScript plugin
   that runs inside the target Godot project's editor. On plugin start it binds a
   WebSocket server on `127.0.0.1` in the **6550–6560** band, generates a session token,
   and publishes `{project path → port, token path}` into a **machine-wide registry**
   (`projects.json`). Without it active in an open editor, the bridge has nothing to dial
   and all calls fail.

The flow is: **MCP host → bridge (stdio) → WebSocket 127.0.0.1:655x → addon → Godot editor**.

**How the bridge picks the editor:** it matches a project path — `GODOT_MCP_PROJECT_PATH`
(set to `${CLAUDE_PROJECT_DIR}` by this plugin's Claude manifest), else its own `cwd`
(Codex) — against the registry. That is the whole isolation story: one editor per project
path, found by path, no "select instance" step.

**Two channels.** The **editor channel** operates on the scene being edited (what gets
saved to `.tscn`). The **runtime channel** operates on the *running game* during a
playtest: when `game_start` launches the game, an injected autoload opens a second
WebSocket (6570–6585) and the `runtime_*`, `input_simulate`, `debugger_get_log` and
`execute_code channel:'runtime'` tools talk to that. Editor-channel writes never affect
the running game and vice versa — `node_set_property` vs `runtime_set_property` is the
canonical pair.

Key entities:

- **Edited scene** — the scene open in the editor. Node paths are relative to its root:
  `"."` is the root, `"./Player"` a direct child, `"./Player/Sprite2D"` deeper.
- **Nodes** — typed tree members (`CharacterBody2D`, `Sprite2D`, user `class_name`
  classes). Properties are read/written by name; engine types are dict-wrapped
  (`{type:'Vector2',x,y}`, `{type:'Resource',path:'res://…'}`, `{type:'LayerMask',…}`).
- **Scripts** — `.gd` / `.cs` / `.gdshader` under `res://`; writes return `valid` +
  `diagnostics` for `.gd`.
- **Resources** — `.tres` files; autoloads; project settings (`project.godot`).
- **Running game** — exists only between `game_start` and `game_stop`; its nodes live
  under `/root/...` absolute paths (`/root/Main/Player`), not the edited-scene `./` paths.

## Tool inventory

The tools below are exposed by the bridge (MCP server key: `godotMCP`). These are the
**real MCP tool identifiers** — call them by these names. They were read from the server's
generated tool reference at `1.0.4` (113 tools, 163 operations: an action-consolidated
tool packs several operations behind an `action`/`operation` discriminator). If a name is
rejected, list the live surface with `discover_tools` rather than guessing.

**The list is dynamic.** 34 tools plus the 2 meta tools are in the initial `tools/list`.
The other 78 live in **28 on-demand groups**; `discover_tools` activates a group and the
host receives `tools/list_changed`. So a tool that is *missing from the list* is usually a
not-yet-discovered group (fix with `discover_tools`) or read-only mode (see Pitfall 5) —
a different failure from a tool that is listed but *fails to call* (editor unreachable —
see Pitfall 1).

### Always-on (34)

| Tool | What it is best for |
|---|---|
| `scene_get_tree` | The edited scene's node tree as nested JSON `{name, class, path, children}` — paths plug straight into the other tools |
| `scene_query` | Searching the tree by class, group, name glob or property condition; paged (`limit` ≤ 200, `next_offset`). Faster than walking the whole tree |
| `scene_spatial_map` | Per-node world position, bounds, size, overlaps and gaps — call **before** placing or moving nodes to find clear space |
| `scene_open` / `scene_create` / `editor_save_scene` | Open a `.tscn` as the edited scene; create a `.tscn` (`if_exists: return|fail|replace`); save (optional `file_path` = save-as). **Nothing persists until `editor_save_scene`** |
| `scene_create_node` / `scene_delete_node` | Create a node of `class_name` under `parent_path` (idempotent: `created`/`returned`); delete by path (refuses the scene root) |
| `node_manage` | Structural ops — `action: rename|reparent|reorder|duplicate` |
| `node_get_property` / `node_set_property` / `node_get_property_list` | Read, write (single or `batch:[…]`), and introspect (`mask: common|all|groups|script`) properties on the **edited** scene |
| `node_set_script` | Attach (or detach with empty path) a `.gd`/`.cs`; returns the `@export` properties |
| `node_call_method` | Call a method with args on an edited-scene node (editor-only) |
| `node_groups` | `action: add|remove|list` group membership (single or batch) |
| `control_set_layout` | Anchor preset + margins on a `Control` in one call (more reliable than setting `anchors_preset` alone) |
| `signal_list` / `signal_manage` | List signals (optionally with connections); connect/disconnect persistently (`CONNECT_PERSIST`, saved in `.tscn`) |
| `script_read` / `script_write` / `script_edit` / `script_check` | Read (paged by line window), create/overwrite, surgically replace a span (byte-exact `old_string`, `edits[]`, `replace_all`), and validate offline. `.gd` writes return `valid` + `diagnostics` — **check `valid` before moving on** |
| `project_get_settings` / `project_set_setting` | Read (prefix filter; secrets dropped) and persist ProjectSettings keys |
| `autoload_manage` | `action: register|unregister|list` autoload singletons — takes effect on next game launch |
| `folder_create` | Create a `res://` directory (recursive, idempotent) |
| `editor_get_console` | Tail the editor Output (`source:'buffer'` on 4.5+; `level_filter`, `text_filter`, `since_id` paging). The primary post-crash diagnostic — reads runtime errors even after `game_stop` |
| `game_start` / `game_stop` | Start a playtest (`scene_path: 'current'|'main'|res://…`, blocks until the runtime channel is ready by default; `if_running:'return'` for idempotence) and stop it |
| `runtime_screenshot` | Capture the running game window (`image_response_mode:'disk'` returns a path instead of inline bytes — use it for large viewports) |
| `runtime_get_script_vars` | Script variables of a live node (names, values, public/private) |
| `input_simulate` | Inject input into the running game: `key`, `mouse_button`, `mouse_motion`, `action`, `click`, `click_node {node_path}`, `send_text`; pass an `events[]` array for a sequence in one call; `position` vs `world_position` coordinates |
| `debugger_get_log` | The game's own output (`print()`, `push_*`) during and after a run, also after a crash. Compile errors do **not** show up here — use `script_check` / `lsp_project_diagnostics` |
| `execute_code` | **DANGER.** Evaluates a GDScript *expression* (no statements, no `=`) in the running game (`channel:'runtime'`, default) or the editor process (`channel:'editor'`). Prefer the typed tools; see Pitfall 6 |

### Meta (2)

| Tool | What it is best for |
|---|---|
| `discover_tools` | Listing and activating the on-demand groups below. Always visible; reach for it when an expected tool is absent |
| `extensions_refresh` | Reloading project-defined extension tools (GDScript-registered custom tools) |

### On-demand groups (28, 78 tools) — activate with `discover_tools`

| Group | Tools |
|---|---|
| `runtime_advanced` | `runtime_get_node_state`, `runtime_set_property`, `animation_player_control` — the runtime-side counterparts of the editor property tools |
| `signals` | `signal_emit` (editor or runtime channel) |
| `scene_advanced` | `scene_diff`, `scene_instantiate` (instance a `.tscn` under a parent) |
| `editor_advanced` | `editor_screenshot` (editor viewport, optional `node_path` focus), `editor_refresh`, `editor_wait_for_idle` |
| `cleanup` | `file_delete`, `scene_delete`, `script_delete`, `resource_delete`, `folder_delete`, `scene_close` (4.5+) |
| `resource_io` | `resource_load`, `resource_write` (`.tres`) |
| `asset_ops` | `asset_list`, `asset_get_dependencies`, `asset_import` (binary assets) |
| `scene_inheritance` | `scene_create_inherited` |
| `user_data` | `save_read`, `save_write`, `save_delete`, `save_list` (`user://` save files) |
| `input_map` | `input_map_list`, `input_map_action`, `input_map_event` |
| `layer_naming` | `layer_names_set`, `layer_names_get` (physics/render layer names used by `LayerMask`) |
| `theme` | `theme_edit` |
| `tilemap` / `tileset` / `tileset_edit` | `tilemap_read_cells`, `tilemap_set_cells`; `tileset_create`, `tileset_add_source`, `tileset_add_alternative`, `tileset_setup_layers`, …; `tileset_edit_physics|terrain|navigation|visuals|custom_data` |
| `spriteframes` | `spriteframes_create`, `spriteframes_edit`, `spriteframes_from_spritesheet` |
| `path_editing` | `path2d_edit_curve`, `collision_from_texture` |
| `3d_tools` | `3d_create_primitive`, `3d_setup_environment`, `3d_create_light`, `3d_create_camera` |
| `particles` / `procedural` / `navigation` | `particles_create`; `procedural_edit_gradient|curve|noise`; `navigation_edit` |
| `animation_authoring` | `animation_keyframe`, `animation_get_keys`, `animationtree_edit`, `animationtree_list` |
| `audio` | `audiobus_edit`, `audiobus_list` |
| `placeholders` | `texture_generate`, `sound_generate` (placeholder content) |
| `lsp_code_analysis` / `lsp_code_navigation` | `lsp_diagnostics`, `lsp_symbols`, `lsp_hover`, `lsp_project_diagnostics`; `lsp_completion`, `lsp_definition`, `lsp_references` — ride Godot's GDScript language server (port 6005, see "Worktrees") |
| `debugger` | `debug_state`, `debug_list_breakpoints`, `debug_set_breakpoint`, `debug_continue` |
| `classdb` | `classdb_get_info`, `classdb_search` — engine class introspection, the right way to answer "which properties does `CharacterBody2D` have" |

Every tool carries read-only / destructive annotations, so the host can auto-allow safe
tools and gate risky ones. Group membership is version-gated: on Godot 4.2–4.4 a few tools
adapt or report the version they need instead of failing cryptically.

## Patterns and recipes

### Inspect the scene

1. `scene_get_tree` to see the edited scene; if the wrong scene is open, `scene_open` the
   right `res://` path first.
2. `scene_query` (by `class`, `group`, name glob or property condition) when you know what
   you are looking for rather than walking the tree.
3. `scene_spatial_map` before placing anything, to find free space and avoid overlaps.
4. `classdb_get_info` (group `classdb`) when you need the property or signal list of an
   engine class rather than of one node.

### Read and modify a node property

1. `node_get_property_list` (`mask:'common'`, or `'script'` for `@export` vars) to learn
   the exact property names and current values.
2. `node_set_property` with the dict-wrapped engine type (`{type:'Vector2',x:100,y:200}`,
   `{type:'Resource',path:'res://art/player.png'}`). Use `batch:[…]` for several at once.
3. Re-read to verify, then `editor_save_scene` — **unsaved changes live only in the
   editor** (Pitfall 3).

### Add a node with a script, and verify it compiles

1. `scene_create_node` (`class_name`, `parent_path`, `node_name`) — idempotent, so a
   re-run returns the existing node instead of a duplicate.
2. `script_write` the `.gd` (or `script_edit` an existing one for a small change). Read
   `valid` and `diagnostics` from the response; fix before continuing.
3. `node_set_script` to attach it; the response lists the `@export` properties you can
   now set with `node_set_property`.
4. `signal_manage` to wire signals persistently; `node_groups action:add` to tag it.
5. `editor_save_scene`.

### Playtest loop

1. `game_start` (default `scene_path:'current'`; `'main'` for the project's main scene).
   It blocks until the runtime channel is up. Needs a **display** — see "Headless".
2. Observe: `runtime_get_node_state` / `runtime_get_script_vars` (absolute `/root/...`
   paths), `runtime_screenshot` (`image_response_mode:'disk'` for anything large), and
   `debugger_get_log` for the game's `print()` output.
3. Act: `input_simulate` with an `events[]` sequence (`click_node` for buttons, `action`
   for input-map actions, `send_text` for text fields) rather than one call per event.
4. Diagnose: `debugger_get_log` (works after a crash too) and `editor_get_console
   level_filter:['error']`. Right after `game_stop`, the first `debugger_get_log` may
   return `GAME_NOT_RUNNING` while the registry settles — retry once.
5. `game_stop` before making structural edits in the editor.

### Capture a screenshot

- Running game: `runtime_screenshot` (always-on, needs an active playtest).
- Editor viewport: `editor_screenshot` (group `editor_advanced`; optional `node_path` —
  a 3D node gets camera framing, a 2D node is selected but not reframed).
- Both need a **GUI editor**; headless returns `HEADLESS_UNSUPPORTED`. A full-size 3D
  capture can exceed the transport buffer (`RESPONSE_TOO_LARGE`) — pass
  `image_response_mode:'disk'` or a lower `image_detail`.

### Find an error after a script change

- Single file: `script_check` (offline, works without the editor's cooperation; real line
  numbers on 4.5+).
- Whole project: `lsp_project_diagnostics` (group `lsp_code_analysis`).
- Runtime failures: `debugger_get_log`, then `editor_get_console level_filter:['error']`.
  A headless editor does not revalidate scripts, so parse errors are not in the console
  there — the tool attaches a `headless_hint` pointing you to `script_check`.

## Godot environments (worktree, main checkout, headless)

Each Godot target the agent works on is a **project path**, and the toolkit keys its
registry by that path. That gives per-environment isolation natively:

1. **Main checkout** — open the editor on the repo root; the bridge (keyed by
   `${CLAUDE_PROJECT_DIR}` on Claude, cwd on Codex) finds it.
2. **Linked worktree** — `git worktree add ../MyGame-feature feature` and open a second
   editor on that path. It binds the next free port in 6550–6560, gets its own token and
   registry entry, and a session rooted in that worktree finds exactly it (upstream
   "Pattern A", explicitly supported).
3. **Human-started editor** — an editor the user opened by hand through the Godot
   project manager on the same path is *already* the registered one. No adoption step
   exists or is needed; just retry the call.

**Not supported:** two editors on the **same** directory ("Pattern C") — the registry is
last-writer-wins, the token filenames collide, and Godot itself races on `user://`. Use a
worktree instead.

### Headless (`godot --headless --editor`)

For CI, SSH-only hosts, or unattended agent sessions:

```
godot --headless --editor --path <checkout>
```

The addon loads, binds its port and registers; most tools then work identically to GUI
mode — file, scene, node, script, ClassDB and project tools included (`scene_open` works
headless, so the whole node/signal chain does). What degrades, with a clear error:

| Tool | Headless |
|---|---|
| `game_start` (and so every `runtime_*`, `input_simulate`, `runtime_screenshot`) | `HEADLESS_UNSUPPORTED` — verify with `script_check`, scene inspection and `editor_get_console` instead |
| `editor_screenshot` | `HEADLESS_UNSUPPORTED` |
| `node_call_method` on a freshly written method, Godot 4.4+ | A headless editor never re-instantiates a reloaded script → `INVALID_METHOD` + a stale-instance `hint`; re-attach with `node_set_script` or use a display editor |
| `editor_get_console` parse errors | Not captured headless; use `script_check` |

Readiness signal: the editor's Output log prints `[MCPServer] listening on
127.0.0.1:<port>` once the addon is up. Until then, calls fail as in Pitfall 1.

**Fresh, never-opened project:** the addon can be enabled without the UI by adding
`[editor_plugins] enabled=PackedStringArray("res://addons/godot_mcp_toolkit/plugin.cfg")`
to `project.godot` — only while **no** editor has the project open.

**Other editor-binary runs take the runtime slot.** Any run of the project with the
editor binary other than `--check-only` — including a headless `--script` test runner —
also starts the runtime channel. Set `GODOT_MCP_RUNTIME=0` on such runs so they do not
steal the runtime slot from the game the agent started.

**Launch automation is an open item.** Unlike `agent-unity-wrapper`, this plugin does not
yet ship a prepare-script that writes an `environment_start`/`environment_stop`
(`agent-worktree`) `start:`/`stop:` block, nor a Godot binary resolution convention. Until
it does, the user starts the editor; the command above is what such a `start:` step would
run.

### Pinning ports (parallel test harnesses only)

Discovery needs no configuration. Pin only when a harness must know ports up front —
and then every pin must be visible to **both** the editor process and the bridge, because
each reads it from its *own* environment: a pin only the bridge sees makes it dial a port
the editor never bound. Per instance, export once in the shell that launches both:
`GODOT_MCP_EDITOR_PORT` (6550–6560 band), `GODOT_MCP_RUNTIME_PORT` (6570–6585), and for
the `lsp_*` tools `--lsp-port <n>` on the editor command line **plus** `GODOT_MCP_LSP_PORT=<n>`
for the bridge. The GDScript language server is a single **machine-wide** port (6005):
any two open editors collide on it, so give every editor its own (`6005`, `6015`, `6025`
… — avoid 6006, Godot's debug adapter). A pinned-but-occupied port fails loudly. This
plugin's manifests set no pins on purpose; put them in the launching environment.

## Pitfalls

1. **Editor-side addon is a hard prerequisite — but a failed call is recoverable
   in-session.** The Godot MCP Toolkit addon must be installed and **Active** in the
   target project, and the editor must be open on that project, or every tool call fails
   with a connection error. The bridge resolves the editor from the registry per connect
   and the registry is rewritten whenever an editor (re)starts, so: open the editor (or
   wait for `[MCPServer] listening on 127.0.0.1:<port>`), then **retry the same call**. If
   it still fails, reconnect the MCP server (`/mcp` → reconnect) — no session restart.
   The tool list is a **static** server-side definition for the always-on set: seeing the
   tools does not mean the editor is up, and a failing call does not mean the tool is
   missing. A connection error that persists after a reconnect means the session is
   rooted in a different path from the one the editor has open (worktree vs main checkout,
   a `subst`/junction path) — compare `${CLAUDE_PROJECT_DIR}` with the editor's project
   path.

2. **Editor channel vs runtime channel.** `node_*` / `scene_*` / `signal_manage` act on
   the edited scene and are saved to disk; `runtime_*` / `input_simulate` act on the
   running game and vanish at `game_stop`. Setting `speed` with `node_set_property` while
   the game runs changes the *next* run, not this one. Node paths differ too: `./Player`
   in the editor, `/root/Main/Player` at runtime. `game_stop` before structural edits.

3. **Unsaved scene state.** Every editor-channel mutation is live in the editor but
   **not on disk** until `editor_save_scene`. A crash or a scene reload loses it. Save
   after each meaningful batch. Conversely, `script_write` *does* write to disk at once —
   and a user's **unsaved** buffer of that same file in the built-in script editor is
   lost when the disk write wins. Ask the user to save open scripts before editing a file
   they are working in.

4. **No project path or port baked into the manifest by design.** The manifest sets
   exactly one env, `GODOT_MCP_PROJECT_PATH=${CLAUDE_PROJECT_DIR}` (Claude only; Codex
   uses cwd), which is host-portable and what makes worktree isolation work. Never add an
   absolute project path, a port pin, or a token path to the manifest — a pin reaches only
   the bridge, never the editor (see "Pinning ports"), and an absolute path breaks the
   plugin for every other user and every other worktree.

5. **Missing tools are usually read-only mode or an undiscovered group.** If only
   read-style tools are visible, `GODOT_MCP_READ_ONLY=1` is set (the dock's read-only
   toggle writes it into the project's `.mcp.json`); turning it off needs a **reconnect**,
   because the tool list is decided at connect time. If a specific tool from the groups
   table is absent, `discover_tools` the group first — and if newly activated tools still
   do not appear, the host did not process `tools/list_changed`: reconnect or upgrade it.

6. **`execute_code` is expression-only and the risk surface.** It accepts a single
   GDScript expression — no `var`, `return`, `if`, `for`, no `=` assignment — and cannot
   reach `EditorInterface`, `Engine`, `OS`, `Input`, `load()`/`preload()`. Property
   chaining on method return values may fail from Variant type erasure; use `scope_path`
   or `.get('prop')`. Prefer `runtime_set_property` / `node_call_method` / `signal_emit`
   for anything they cover; keep `execute_code` calls small and single-purpose; never run
   an unrequested destructive expression. All file tools are sandboxed to `res://` by the
   addon, `execute_code` is not sandboxed beyond what the expression language allows.

7. **A project `.mcp.json` with a `godot-mcp-toolkit` entry doubles the server.** The
   addon's dock offers to write one. With this plugin installed it is redundant: the host
   would launch two bridges against the same editor and show every tool twice under two
   prefixes. If you see duplicated tools, tell the user to remove that entry (or not
   commit the dock-written file) and reconnect.

8. **`npx` cold start and stale cache.** The first launch downloads the bridge before the
   first JSON-RPC byte and can exceed the host's handshake timeout — reconnect once npm
   has cached it, or pre-warm with `npx -y @npgamedev/godot-mcp-server@1.0.4 --tools-count`
   (needs no editor). npm's `could not determine executable to run` means a stale `_npx`
   cache entry — delete it under `npm config get cache`. On Windows, `spawn npx ENOENT` /
   `EINVAL` means the host is too old to start the `.cmd` shim — update Claude Code.

9. **Godot version gates.** `scene_close` needs 4.5+; toast notifications 4.4+; LSP
   cross-project safety 4.5+; real diagnostic line numbers from `script_check` 4.5+. On
   4.2.0/4.2.1 a script write is never hot-reloaded (nodes keep the old code until the
   editor relaunches — the response carries a stale-instance `hint`). C# projects need
   the mono editor build or `.cs` scripts will not load. Scenes saved by a newer Godot do
   not open in an older one — an engine constraint, not a tool failure.
