<#
.SYNOPSIS
  Idempotent, repo-level preparation for per-environment Godot editors.

.DESCRIPTION
  Run this ONCE at the root of a Godot project repository. It prepares the repo so
  that `agent-worktree`'s `environment_start` / `environment_stop` boot and kill an
  editor (with the Godot MCP Toolkit addon) for a given checkout - a linked worktree,
  or the main checkout via `checkout_path=<repo root>`. The toolkit keys its
  machine-wide registry by project path, so every checkout gets its own editor,
  port and token with no further wiring. Commit the changes afterwards.

  Writes into the target repo:
    * `.seretos/worktree-setup.yml` - ONLY when absent (existence, via Test-Path, is
      the only check; the file is never read or rewritten once it exists). A fresh
      file carries `version: 1`, `isolation: full` and a managed `start:` block
      (`default` = headless editor, `gui` = windowed editor) plus one `stop:` step.
    * `.seretos/godot-mcp-launch.ps1` - generated, owned by this plugin, ALWAYS
      overwritten on every run. Start and stop logic live here (not in the yml) so a
      fix reaches already-prepared repos the next time this script runs.
    * `.gitignore` - `.godot-mcp/` (pid file + editor log) is appended if missing.

  Also installs and enables the Godot MCP Toolkit addon (needs a `project.godot`;
  without one the addon step warns and is skipped):
    * `addons/godot_mcp_toolkit/` is installed from the toolkit release zip at the
      pinned version (`$script:ToolkitVersion`, 1.0.4 - the version matching the
      bridge pinned in the plugin manifests). An addon already at that version is
      never touched (no download, no write). An addon at ANOTHER version is left
      byte-identical, warned about (both versions named) and NOT enabled; delete
      `addons/godot_mcp_toolkit/` and re-run to replace it.
    * `res://addons/godot_mcp_toolkit/plugin.cfg` is added to `project.godot`'s
      `[editor_plugins] enabled=PackedStringArray(...)`. That edit is skipped with a
      warning while any godot* process is running (never edit project.godot under a
      running editor); the addon files are still installed then.

.PARAMETER RepoRoot
  Repo to prepare. Defaults to `git rev-parse --show-toplevel`, else the cwd.

.PARAMETER AddonSource
  Where to get the addon zip: an http(s) URL (default: the pinned GitHub release
  asset) or the path of a local zip (a missing path is an error, never a fallback to
  the network). Only read when the addon is absent.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$AddonSource
)

# Addon version to install. The bridge (@npgamedev/godot-mcp-server) is versioned
# independently upstream, so this is NOT derived from the manifests: re-check it
# whenever the bridge pin in plugin.json is bumped.
$script:ToolkitVersion = '1.0.4'
$script:ToolkitUrl = "https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/v$($script:ToolkitVersion)/godot-mcp-toolkit-$($script:ToolkitVersion).zip"
if (-not $AddonSource) { $AddonSource = $script:ToolkitUrl }

$ErrorActionPreference = 'Stop'

function Write-Info  { param([string]$Message) Write-Host "[prepare-godot-worktree] $Message" }
function Write-Warn2 { param([string]$Message) Write-Warning "[prepare-godot-worktree] $Message" }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Adds the toolkit addon to project.godot's enabled editor plugins. Idempotent.
# Skipped (warning) while any godot* process runs - a conservative stand-in for
# "no editor has this project open".
function Enable-GodotAddon {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectGodotPath)

    $entry = 'res://addons/godot_mcp_toolkit/plugin.cfg'
    $text = [System.IO.File]::ReadAllText($ProjectGodotPath)
    if ($text.Contains($entry)) { return }

    if (Get-Process -Name 'godot*' -ErrorAction SilentlyContinue) {
        Write-Warning "[prepare-godot-worktree] A godot process is running - not editing project.godot under a running editor. Close the editor and re-run this script, or enable the addon under Project Settings -> Plugins."
        return
    }

    $quoted = '"' + $entry + '"'
    if ($text -match '(?m)^enabled=PackedStringArray\(') {
        $text = [regex]::Replace($text, '(?m)^enabled=PackedStringArray\((.*)\)[ \t]*$', {
            param($m)
            $inner = $m.Groups[1].Value.Trim()
            if ($inner) { "enabled=PackedStringArray($inner, $quoted)" } else { "enabled=PackedStringArray($quoted)" }
        })
    } elseif ($text -match '(?m)^\[editor_plugins\][ \t]*$') {
        $text = [regex]::Replace($text, '(?m)^\[editor_plugins\][ \t]*$', "[editor_plugins]`n`nenabled=PackedStringArray($quoted)", 1)
    } else {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
        $text += "`n[editor_plugins]`n`nenabled=PackedStringArray($quoted)`n"
    }
    Write-Utf8NoBom -Path $ProjectGodotPath -Content $text
    Write-Host "[prepare-godot-worktree] Enabled the Godot MCP Toolkit addon in project.godot."
}

# Returns the version="..." of an addon plugin.cfg, or $null.
function Get-AddonCfgVersion {
    param([string]$CfgPath)
    if (-not (Test-Path -LiteralPath $CfgPath)) { return $null }
    $m = [regex]::Match([System.IO.File]::ReadAllText($CfgPath), '(?m)^version\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Installs addons/godot_mcp_toolkit at the pinned version. Returns $true when the
# addon at the pinned version is present afterwards, $false when another version was
# left in place. Throws on a bad/missing source or an archive at the wrong version.
function Install-GodotAddon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Source
    )
    $pin = $script:ToolkitVersion
    $dest = Join-Path $RepoRoot 'addons/godot_mcp_toolkit'
    $have = Get-AddonCfgVersion (Join-Path $dest 'plugin.cfg')
    if ($null -ne $have) {
        if ($have -eq $pin) {
            Write-Info "Godot MCP Toolkit addon already at $pin - left untouched."
            return $true
        }
        Write-Warning "[prepare-godot-worktree] addons/godot_mcp_toolkit is at version '$have', expected ${pin} - left untouched and NOT enabled. Delete addons/godot_mcp_toolkit/ and re-run to replace it."
        return $false
    }
    if (Test-Path -LiteralPath $dest) {
        throw "addons/godot_mcp_toolkit exists without a readable plugin.cfg; delete it and re-run."
    }

    $isUrl = $Source -match '^https?://'
    if (-not $isUrl -and -not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Addon source not found: ${Source}"
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('pgw-addon-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $zip = $Source
        if ($isUrl) {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $zip = Join-Path $work 'addon.zip'
            Write-Info "Downloading $Source"
            Invoke-WebRequest -Uri $Source -OutFile $zip -UseBasicParsing
        }
        $ex = Join-Path $work 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $cfgs = @(Get-ChildItem -LiteralPath $ex -Recurse -File -Filter plugin.cfg |
            Where-Object { ($_.FullName -replace '\\', '/') -match '/addons/godot_mcp_toolkit/plugin\.cfg$' })
        if ($cfgs.Count -ne 1) { throw "Addon archive does not contain exactly one addons/godot_mcp_toolkit/plugin.cfg (found $($cfgs.Count)): ${Source}" }
        $got = Get-AddonCfgVersion $cfgs[0].FullName
        if ($got -ne $pin) { throw "Addon archive is version '$got', expected ${pin}: ${Source}" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $cfgs[0].DirectoryName -Destination $dest -Recurse
        Write-Info "Installed Godot MCP Toolkit addon $pin into addons/godot_mcp_toolkit."
        return $true
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
    }
}

# Default-run addon step: install, then enable (guarded) when the pinned version is there.
function Initialize-GodotAddon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Source
    )
    $projectGodot = Join-Path $RepoRoot 'project.godot'
    if (-not (Test-Path -LiteralPath $projectGodot)) {
        Write-Warn2 "No 'project.godot' under repo root - skipping addon install and enable."
        return
    }
    if (Install-GodotAddon -RepoRoot $RepoRoot -Source $Source) {
        Enable-GodotAddon -ProjectGodotPath $projectGodot
    }
}

# The managed start/stop block. Single-quoted here-string: NO interpolation - every
# `$` below belongs to the pwsh that the worktree runner executes at start/stop time.
$managedBlock = @'
# >>> agent-godot-wrapper managed: per-environment Godot editor (generated by agent-godot-wrapper; this project owns this block - edit it freely)
start:
  - name: default
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/godot-mcp-launch.ps1') -Variant default -CheckoutPath $proj
  - name: gui
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/godot-mcp-launch.ps1') -Variant gui -CheckoutPath $proj
stop:
  - name: godot-mcp-stop
    shell: pwsh
    run: |
      $ErrorActionPreference = 'SilentlyContinue'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      $launcher = Join-Path $proj '.seretos/godot-mcp-launch.ps1'
      if (Test-Path $launcher) { & $launcher -Stop -CheckoutPath $proj }
      exit 0
# <<< agent-godot-wrapper managed
'@

# Written into <repo>/.seretos/godot-mcp-launch.ps1 (always overwritten).
# Single-quoted here-string: every `$` below belongs to the pwsh that later runs it.
$launchScript = @'
# >>> agent-godot-wrapper generated: godot-mcp-launch.ps1 - do not hand-edit; re-run scripts/prepare-godot-worktree.ps1 to update
<#
.SYNOPSIS
  Boots (or stops) the Godot editor for one checkout.

.DESCRIPTION
  Start: & godot-mcp-launch.ps1 -Variant <default|gui> -CheckoutPath <path>
    default = `godot --headless --editor` (CI / unattended; no screenshots or playtests)
    gui     = windowed `godot --editor` (needs a display)
  Editor binary, first match wins: $env:GODOT_PATH, $env:GODOT_EDITOR_PATH (both must
  name an existing file, else the step fails naming the variable), `godot` / `godot4`
  on PATH, else a pinned Godot 4.7.2-stable Windows console build provisioned once into
  %LOCALAPPDATA%\agent-godot-wrapper\godot\4.7.2-stable\ and reused afterwards.
  Set GODOT_PATH to use your own editor instead. Provisioning is Windows-only.
  Readiness: waits up to -WaitSeconds for the editor log to print
  `[MCPServer] listening on 127.0.0.1:<port>`, or (Windows) for a fresh entry for this
  checkout in %APPDATA%\godot-mcp-toolkit\projects.json (an entry that already existed
  before the launch, unchanged, does not count). State lives in <path>/.godot-mcp/
  (godot.pid, editor.log). On timeout the step fails and the pid file is kept so
  environment_stop can clean up.

  Stop: & godot-mcp-launch.ps1 -Stop -CheckoutPath <path>
  Kills the pid in .godot-mcp/godot.pid and removes it; silent no-op otherwise.
#>
param(
    [ValidateSet('default', 'gui')]
    [string]$Variant = 'default',
    [string]$CheckoutPath,
    [switch]$Stop,
    [int]$WaitSeconds = 120
)

$ErrorActionPreference = 'Stop'
# PowerShell 5.1 does not define $IsWindows; treat its absence as Windows.
$script:OnWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

# Pinned editor build provisioned when nothing else resolves.
$script:GodotVersion = '4.7.2-stable'
$script:GodotExe = "Godot_v$($script:GodotVersion)_win64_console.exe"
$script:GodotUrl = "https://github.com/godotengine/godot-builds/releases/download/$($script:GodotVersion)/Godot_v$($script:GodotVersion)_win64.exe.zip"

function Get-GodotLaunchArgs {
    param(
        [ValidateSet('default', 'gui')][string]$Variant = 'default',
        [Parameter(Mandatory)][string]$CheckoutPath
    )
    $a = @()
    if ($Variant -eq 'default') { $a += '--headless' }
    $a += '--editor'
    $a += '--path';     $a += $CheckoutPath
    $a += '--log-file'; $a += (Join-Path $CheckoutPath '.godot-mcp/editor.log')
    return $a
}

function Get-GodotInstallDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { throw "LOCALAPPDATA is not set; cannot locate the Godot install directory. Set GODOT_PATH to the editor executable." }
    return (Join-Path $base "agent-godot-wrapper/godot/$($script:GodotVersion)")
}

# Installs the pinned console build into Get-GodotInstallDir and returns the exe path.
# An existing install is returned untouched (source never resolved).
function Install-GodotEditor {
    param([Parameter(Mandatory)][string]$Source)
    $dir = Get-GodotInstallDir
    $exe = Join-Path $dir $script:GodotExe
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    if (Test-Path -LiteralPath $dir) {
        throw "Godot install directory $dir exists but lacks $($script:GodotExe); delete it and re-run."
    }
    $isUrl = $Source -match '^https?://'
    if (-not $isUrl -and -not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Godot source not found: $Source"
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('agw-godot-' + [System.IO.Path]::GetRandomFileName())
    $staging = "$dir.partial-" + [System.IO.Path]::GetRandomFileName()
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = $Source
        if ($isUrl) {
            $zip = Join-Path $work 'godot.zip'
            Write-Host "godot-mcp-launch: downloading Godot $($script:GodotVersion) from $Source"
            $pp = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $zip } finally { $ProgressPreference = $pp }
        }
        $ex = Join-Path $work 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $found = @(Get-ChildItem -LiteralPath $ex -Recurse -File -Filter $script:GodotExe)
        if ($found.Count -ne 1) {
            throw "Godot archive must contain exactly one $($script:GodotExe) (the $($script:GodotVersion) console build); found $($found.Count)."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null
        Copy-Item -LiteralPath $found[0].Directory.FullName -Destination $staging -Recurse
        try { Move-Item -LiteralPath $staging -Destination $dir -ErrorAction Stop }
        catch {
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw }
        }
        Write-Host "godot-mcp-launch: Provisioned Godot $($script:GodotVersion) into $dir"
        return $exe
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $work, $staging -ErrorAction SilentlyContinue
    }
}

# Precedence: GODOT_PATH > GODOT_EDITOR_PATH > godot/godot4 on PATH > provisioned build.
function Resolve-GodotBinary {
    param([string]$Source = $script:GodotUrl)
    foreach ($v in @('GODOT_PATH', 'GODOT_EDITOR_PATH')) {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) {
            if (-not (Test-Path -LiteralPath $val -PathType Leaf)) { throw "$v is set to '$val', which is not an existing file." }
            return $val
        }
    }
    foreach ($n in @('godot', 'godot4')) {
        $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    if (-not $script:OnWindows) {
        throw "No Godot editor binary found: automatic provisioning is Windows-only; set GODOT_PATH to the editor executable (or put 'godot' / 'godot4' on PATH)."
    }
    return (Install-GodotEditor -Source $Source)
}

function Read-SharedText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
        try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-NormalizedPath {
    param([string]$Path)
    return (($Path -replace '\\', '/').TrimEnd('/')).ToLowerInvariant()
}

# The registry entry (as compact JSON) for this checkout, or $null. Windows only.
function Get-RegistryEntry {
    param([string]$CheckoutPath)
    if (-not $script:OnWindows -or -not $env:APPDATA) { return $null }
    $file = Join-Path $env:APPDATA 'godot-mcp-toolkit/projects.json'
    $raw = Read-SharedText $file
    if (-not $raw) { return $null }
    try { $reg = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $reg -or -not $reg.by_path) { return $null }
    $want = Get-NormalizedPath $CheckoutPath
    foreach ($p in $reg.by_path.PSObject.Properties) {
        if ((Get-NormalizedPath $p.Name) -eq $want) { return ($p.Value | ConvertTo-Json -Compress -Depth 8) }
    }
    return $null
}

function Stop-GodotEditor {
    param([string]$CheckoutPath)
    $ErrorActionPreference = 'SilentlyContinue'
    $pidFile = Join-Path $CheckoutPath '.godot-mcp/godot.pid'
    if (-not (Test-Path $pidFile)) { return }
    $p = (Get-Content $pidFile | Select-Object -First 1)
    if ($p) {
        $p = "$p".Trim()
        if ($p -match '^\d+$') {
            if ($script:OnWindows) { & taskkill /PID $p /T /F *> $null }
            else { & kill -TERM $p *> $null }
        }
    }
    Remove-Item -Force $pidFile
}

function Start-GodotEditor {
    param([string]$Variant, [string]$CheckoutPath, [int]$WaitSeconds)
    $stateDir = Join-Path $CheckoutPath '.godot-mcp'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $pidFile = Join-Path $stateDir 'godot.pid'
    $logFile = Join-Path $stateDir 'editor.log'

    # Two editors on one directory is unsupported upstream: reuse a live one.
    if (Test-Path $pidFile) {
        $old = (Get-Content $pidFile | Select-Object -First 1)
        if ($old -and "$old".Trim() -match '^\d+$' -and (Get-Process -Id ([int]"$old".Trim()) -ErrorAction SilentlyContinue)) {
            Write-Host "godot-mcp-launch: editor already running for $CheckoutPath (pid $("$old".Trim()))."
            return
        }
    }

    $bin = Resolve-GodotBinary
    Write-Host "godot-mcp-launch: Godot editor $bin"
    $before = Get-RegistryEntry $CheckoutPath
    Remove-Item -Force $logFile -ErrorAction SilentlyContinue

    $argList = @(Get-GodotLaunchArgs -Variant $Variant -CheckoutPath $CheckoutPath | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    })
    $sp = @{ FilePath = $bin; ArgumentList = $argList; PassThru = $true; WorkingDirectory = $CheckoutPath }
    if ($script:OnWindows -and $Variant -eq 'default') { $sp.WindowStyle = 'Hidden' }
    $proc = Start-Process @sp
    [System.IO.File]::WriteAllText($pidFile, [string]$proc.Id)

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-SharedText $logFile), '\[MCPServer\] listening on 127\.0\.0\.1:(\d+)')
        if ($m.Success) {
            Write-Host "godot-mcp-launch: $Variant editor ready for $CheckoutPath on port $($m.Groups[1].Value) (pid $($proc.Id))."
            return
        }
        $now = Get-RegistryEntry $CheckoutPath
        if ($now -and $now -ne $before) {
            Write-Host "godot-mcp-launch: $Variant editor registered for $CheckoutPath (pid $($proc.Id))."
            return
        }
        if ($proc.HasExited) {
            throw "godot-mcp-launch: the editor exited early (code $($proc.ExitCode)) before becoming ready. See $logFile"
        }
        Start-Sleep -Milliseconds 500
    }
    throw "godot-mcp-launch: editor not ready after $WaitSeconds s (pid $($proc.Id) kept in $pidFile; run environment_stop to clean up). See $logFile"
}

# Skipped when dot-sourced (tests, reuse); $MyInvocation.InvocationName is '.' then.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $CheckoutPath) { throw 'godot-mcp-launch.ps1: -CheckoutPath is required' }
    $CheckoutPath = [System.IO.Path]::GetFullPath($CheckoutPath)
    if ($Stop) { Stop-GodotEditor -CheckoutPath $CheckoutPath }
    else { Start-GodotEditor -Variant $Variant -CheckoutPath $CheckoutPath -WaitSeconds $WaitSeconds }
}
'@

# Skipped when dot-sourced (tests load Enable-GodotAddon this way).
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $RepoRoot) {
        try {
            $top = (& git rev-parse --show-toplevel 2>$null)
            if ($LASTEXITCODE -eq 0 -and $top) { $RepoRoot = $top.Trim() }
        } catch { }
    }
    if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    Write-Info "Repo root: $RepoRoot"

    $projectGodot = Join-Path $RepoRoot 'project.godot'
    if (-not (Test-Path $projectGodot)) {
        Write-Warn2 "No 'project.godot' under repo root - this may not be a Godot project. Continuing anyway."
    }

    # 1. worktree-setup.yml: only when absent, never read.
    $ymlPath = Join-Path $RepoRoot '.seretos/worktree-setup.yml'
    if (-not (Test-Path $ymlPath)) {
        Write-Utf8NoBom -Path $ymlPath -Content ("version: 1`nisolation: full`n`n" + $managedBlock + "`n")
        Write-Info 'Created .seretos/worktree-setup.yml with managed Godot start/stop block.'
    } else {
        Write-Info '.seretos/worktree-setup.yml already exists - left untouched.'
    }

    # 2. launcher: always regenerated.
    Write-Utf8NoBom -Path (Join-Path $RepoRoot '.seretos/godot-mcp-launch.ps1') -Content ($launchScript + "`n")
    Write-Info 'Wrote .seretos/godot-mcp-launch.ps1.'

    # 3. .gitignore: runtime state of the editor.
    $giPath = Join-Path $RepoRoot '.gitignore'
    $giText = if (Test-Path $giPath) { [System.IO.File]::ReadAllText($giPath) } else { '' }
    if (-not (($giText -split "`r?`n") | Where-Object { $_.Trim() -eq '.godot-mcp/' })) {
        if ($giText.Length -gt 0 -and -not $giText.EndsWith("`n")) { $giText += "`n" }
        Write-Utf8NoBom -Path $giPath -Content ($giText + ".godot-mcp/`n")
        Write-Info 'Added .godot-mcp/ to .gitignore.'
    }

    # 4. addon: install at the pinned version, then enable.
    Initialize-GodotAddon -RepoRoot $RepoRoot -Source $AddonSource
}
