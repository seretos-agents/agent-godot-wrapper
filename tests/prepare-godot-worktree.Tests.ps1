#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
  Pester 5 tests for scripts/prepare-godot-worktree.ps1 (ticket #1).

  CI / default:   Invoke-Pester -Path tests/prepare-godot-worktree.Tests.ps1 -ExcludeTag Live -CI -Output Detailed
  Live (by hand): Invoke-Pester -Path tests/prepare-godot-worktree.Tests.ps1 -TagFilter Live -Output Detailed
                  needs GODOT_EDITOR_PATH and GODOT_LIVE_PROJECT (a git repo with the
                  Godot MCP Toolkit addon enabled), a display, node/npx and git.

  Contracts these tests pin on the script under test (the implementation must honour them):
    * `pwsh -File scripts/prepare-godot-worktree.ps1 -RepoRoot <dir> [-EnableAddon]` writes
      <dir>/.seretos/worktree-setup.yml (only if absent), <dir>/.seretos/godot-mcp-launch.ps1
      (always) and appends `.godot-mcp/` to <dir>/.gitignore (once).
    * The yml has `version: 1`, `isolation: full`, `start:` steps named `default` and `gui`
      (each `run:` passes `-Variant <name>`), and exactly one `stop:` step whose `run: |`
      body is a PowerShell script reading $env:WORKTREE_PATH.
    * Both scripts are loadable by dot-sourcing WITHOUT running their main body
      (guard on $MyInvocation.InvocationName -eq '.').
    * Launcher exposes `Get-GodotLaunchArgs -Variant <default|gui> -CheckoutPath <p>` returning
      the editor argument list (`--headless` only for default; always `--editor`, `--path`,
      `--log-file`).
    * Prepare script exposes `Enable-GodotAddon -ProjectGodotPath <p>`; it must call
      Get-Process and, when any godot* process runs, leave the file untouched and emit a warning.
    * Launcher `-Stop -CheckoutPath <p>` kills the pid in <p>/.godot-mcp/godot.pid and removes the file;
      silent no-op (exit 0, no output) when there is no pid file or the pid is stale.
#>

BeforeDiscovery {
    $script:godotRunning = [bool](Get-Process -Name 'godot*' -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot   = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot 'scripts/prepare-godot-worktree.ps1'

    function New-TempGodotRepo {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pgw-' + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp 'project.godot'),
            "config_version=5`n`n[application]`n`nconfig/name=`"fixture`"`n")
        return $tmp
    }

    # Builds a fixture addon archive: addons/godot_mcp_toolkit/{plugin.cfg,plugin.gd}.
    # -TopFolder nests everything under one extra top-level folder (alternate zip layout).
    function New-FixtureAddonZip {
        param([string]$Version, [string]$GdContent = '# fixture', [switch]$TopFolder)
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ('pgw-zip-' + [System.IO.Path]::GetRandomFileName())
        $tree = Join-Path $base 'tree'
        $addon = Join-Path $tree 'addons/godot_mcp_toolkit'
        if ($TopFolder) { $addon = Join-Path $tree 'godot-mcp-toolkit-pkg/addons/godot_mcp_toolkit' }
        New-Item -ItemType Directory -Force -Path $addon | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $addon 'plugin.cfg'),
            "[plugin]`n`nname=`"Godot MCP Toolkit`"`nscript=`"plugin.gd`"`nversion=`"$Version`"`n")
        [System.IO.File]::WriteAllText((Join-Path $addon 'plugin.gd'), $GdContent)
        $zip = Join-Path $base 'toolkit.zip'
        Compress-Archive -Path (Join-Path $tree '*') -DestinationPath $zip
        return $zip
    }

    # Sorted "relative path|sha256|mtime ticks" lines for every file under a directory.
    function Get-TreeSnapshot {
        param([string]$Dir)
        $root = (Resolve-Path -LiteralPath $Dir).Path
        @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length)
            '{0}|{1}|{2}' -f $rel, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.LastWriteTimeUtc.Ticks
        })
    }

    # Always injects a local fixture archive (1.0.4 unless -AddonSource) so no run touches the network.
    function Invoke-Prepare {
        param([string]$Root, [string]$AddonSource)
        if (-not $AddonSource) {
            if (-not $script:zip104) { $script:zip104 = New-FixtureAddonZip -Version '1.0.4' }
            $AddonSource = $script:zip104
        }
        $a = @('-NoProfile', '-File', $script:scriptPath, '-RepoRoot', $Root, '-AddonSource', $AddonSource)
        $out = & pwsh @a 2>&1 | Out-String
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function Get-YmlSections {
        param([string]$Yml)
        $startIdx = [regex]::Match($Yml, '(?m)^start:\s*$')
        $stopIdx  = [regex]::Match($Yml, '(?m)^stop:\s*$')
        if (-not $startIdx.Success -or -not $stopIdx.Success) { return @{ Start = ''; Stop = '' } }
        if ($startIdx.Index -lt $stopIdx.Index) {
            return @{ Start = $Yml.Substring($startIdx.Index, $stopIdx.Index - $startIdx.Index)
                      Stop  = $Yml.Substring($stopIdx.Index) }
        }
        return @{ Start = $Yml.Substring($startIdx.Index)
                  Stop  = $Yml.Substring($stopIdx.Index, $startIdx.Index - $stopIdx.Index) }
    }

    function Get-StepNames {
        param([string]$Section)
        @([regex]::Matches($Section, '(?m)^\s*-?\s*name:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    }

    # Extract the indented body under `run: |` of the first step in a section, dedented.
    function Get-RunBody {
        param([string]$Section, [string]$StepName)
        $lines = $Section -split "`r?`n"
        $i = 0
        if ($StepName) {
            for (; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "name:\s*$([regex]::Escape($StepName))\s*$") { break } }
        }
        for (; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^(\s*)(?:-\s*)?run:\s*\|\s*$') { break } }
        if ($i -ge $lines.Count) { return $null }
        $runIndent = $Matches[1].Length
        $body = [System.Collections.Generic.List[string]]::new()
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if ($l.Trim() -eq '') { $body.Add(''); continue }
            $ind = $l.Length - $l.TrimStart().Length
            if ($ind -le $runIndent) { break }
            $body.Add($l)
        }
        $min = ($body | Where-Object { $_ -ne '' } | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
        return (($body | ForEach-Object { if ($_ -eq '') { '' } else { $_.Substring($min) } }) -join "`n")
    }

    # Run a step body for real as a standalone pwsh script with WORKTREE_PATH injected.
    function Invoke-StepBody {
        param([string]$Body, [string]$WorktreePath)
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ('pgw-step-' + [System.IO.Path]::GetRandomFileName() + '.ps1')
        [System.IO.File]::WriteAllText($f, $Body)
        $old = $env:WORKTREE_PATH
        try {
            $env:WORKTREE_PATH = $WorktreePath
            $out = & pwsh -NoProfile -File $f *>&1 | Out-String
            return @{ Output = $out; ExitCode = $LASTEXITCODE }
        } finally {
            $env:WORKTREE_PATH = $old
            Remove-Item -Force $f -ErrorAction SilentlyContinue
        }
    }

    function Start-StandIn {
        Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 600' -PassThru
    }

    function Wait-ProcessGone {
        param([int]$ProcessId, [int]$Seconds = 10)
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }
}

Describe 'prepare-godot-worktree.ps1 R1: create' {
    BeforeEach { $script:tmp = New-TempGodotRepo }
    AfterEach  { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It 'fresh repo: creates yml with default+gui start and one stop, and the launch script' {
        $r = Invoke-Prepare -Root $script:tmp
        $ymlPath = Join-Path $script:tmp '.seretos/worktree-setup.yml'
        $launch  = Join-Path $script:tmp '.seretos/godot-mcp-launch.ps1'
        $ymlPath | Should -Exist
        $launch  | Should -Exist
        $yml = Get-Content -Raw $ymlPath
        $yml | Should -Match '(?m)^version:\s*1\s*$'
        $yml | Should -Match '(?m)^isolation:\s*full\s*$'
        $s = Get-YmlSections $yml
        (Get-StepNames $s.Start) | Should -Be @('default', 'gui')
        @(Get-StepNames $s.Stop).Count | Should -Be 1
    }

    It 'appends .godot-mcp/ to the target .gitignore' {
        Invoke-Prepare -Root $script:tmp | Out-Null
        (Get-Content -Raw (Join-Path $script:tmp '.gitignore')) | Should -Match '(?m)^\.godot-mcp/\s*$'
    }

    It 'each start step passes its own -Variant' {
        Invoke-Prepare -Root $script:tmp | Out-Null
        $s = Get-YmlSections (Get-Content -Raw (Join-Path $script:tmp '.seretos/worktree-setup.yml'))
        (Get-RunBody $s.Start 'default') | Should -Match '-Variant\s+default'
        (Get-RunBody $s.Start 'gui')     | Should -Match '-Variant\s+gui'
    }

    It 'launcher args: default is headless, gui is not; both pass --editor --path --log-file' {
        Invoke-Prepare -Root $script:tmp | Out-Null
        . (Join-Path $script:tmp '.seretos/godot-mcp-launch.ps1')
        $d = @(Get-GodotLaunchArgs -Variant default -CheckoutPath $script:tmp)
        $g = @(Get-GodotLaunchArgs -Variant gui -CheckoutPath $script:tmp)
        $d | Should -Contain '--headless'
        $g | Should -Not -Contain '--headless'
        foreach ($a in @($d, $g)) {
            $a | Should -Contain '--editor'
            $a | Should -Contain '--path'
            $a | Should -Contain '--log-file'
        }
    }
}

Describe 'prepare-godot-worktree.ps1 R2: idempotency' {
    BeforeEach { $script:tmp = New-TempGodotRepo }
    AfterEach  { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It 'second run: yml byte-identical, hand-edited launcher restored' {
        Invoke-Prepare -Root $script:tmp | Out-Null
        $yml    = Join-Path $script:tmp '.seretos/worktree-setup.yml'
        $launch = Join-Path $script:tmp '.seretos/godot-mcp-launch.ps1'
        $ymlBefore    = [System.IO.File]::ReadAllBytes($yml)
        $launchBefore = [System.IO.File]::ReadAllBytes($launch)
        [System.IO.File]::WriteAllText($launch, '# hand edited')
        Invoke-Prepare -Root $script:tmp | Out-Null
        [System.IO.File]::ReadAllBytes($yml)    | Should -Be $ymlBefore
        [System.IO.File]::ReadAllBytes($launch) | Should -Be $launchBefore
    }

    It 'a pre-existing foreign yml stays byte-identical' {
        $dir = Join-Path $script:tmp '.seretos'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $yml = Join-Path $dir 'worktree-setup.yml'
        [System.IO.File]::WriteAllText($yml, "version: 1`nisolation: none`n")
        $before = [System.IO.File]::ReadAllBytes($yml)
        Invoke-Prepare -Root $script:tmp | Out-Null
        [System.IO.File]::ReadAllBytes($yml) | Should -Be $before
    }

    It 'a zero-byte yml stays zero-byte' {
        $dir = Join-Path $script:tmp '.seretos'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $yml = Join-Path $dir 'worktree-setup.yml'
        [System.IO.File]::WriteAllBytes($yml, [byte[]]@())
        Invoke-Prepare -Root $script:tmp | Out-Null
        (Get-Item $yml).Length | Should -Be 0
    }

    It 'a second run does not duplicate the .gitignore line' {
        Invoke-Prepare -Root $script:tmp | Out-Null
        Invoke-Prepare -Root $script:tmp | Out-Null
        @(Get-Content (Join-Path $script:tmp '.gitignore') | Where-Object { $_.Trim() -eq '.godot-mcp/' }).Count | Should -Be 1
    }
}

Describe 'prepare-godot-worktree.ps1 R3/R4: stop step' {
    BeforeEach {
        $script:tmp = New-TempGodotRepo
        Invoke-Prepare -Root $script:tmp | Out-Null
        $yml = Get-Content -Raw (Join-Path $script:tmp '.seretos/worktree-setup.yml') -ErrorAction SilentlyContinue
        $script:stopBody = if ($yml) { Get-RunBody (Get-YmlSections $yml).Stop $null } else { $null }
        $script:standIn = $null
    }
    AfterEach {
        if ($script:standIn) { Stop-Process -Id $script:standIn.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }

    It 'stop: kills pid-file process and removes pid file' {
        $script:stopBody | Should -Not -BeNullOrEmpty
        $script:standIn = Start-StandIn
        $pidDir = Join-Path $script:tmp '.godot-mcp'
        New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
        $pidFile = Join-Path $pidDir 'godot.pid'
        [System.IO.File]::WriteAllText($pidFile, [string]$script:standIn.Id)
        (Get-Process -Id $script:standIn.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty

        $r = Invoke-StepBody -Body $script:stopBody -WorktreePath $script:tmp

        $r.ExitCode | Should -Be 0
        (Wait-ProcessGone -ProcessId $script:standIn.Id -Seconds 10) | Should -BeTrue
        $pidFile | Should -Not -Exist
    }

    It 'second stop: silent no-op' {
        $script:stopBody | Should -Not -BeNullOrEmpty
        $script:standIn = Start-StandIn
        $pidDir = Join-Path $script:tmp '.godot-mcp'
        New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $pidDir 'godot.pid'), [string]$script:standIn.Id)
        Invoke-StepBody -Body $script:stopBody -WorktreePath $script:tmp | Out-Null

        $r = Invoke-StepBody -Body $script:stopBody -WorktreePath $script:tmp

        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
    }

    It 'stale pid (dead process): file removed, silent, exit 0' {
        $script:stopBody | Should -Not -BeNullOrEmpty
        $dead = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru
        $dead.WaitForExit()
        $pidDir = Join-Path $script:tmp '.godot-mcp'
        New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
        $pidFile = Join-Path $pidDir 'godot.pid'
        [System.IO.File]::WriteAllText($pidFile, [string]$dead.Id)

        $r = Invoke-StepBody -Body $script:stopBody -WorktreePath $script:tmp

        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
        $pidFile | Should -Not -Exist
    }
}

Describe 'prepare-godot-worktree.ps1 R5: -EnableAddon' {
    BeforeEach { $script:tmp = New-TempGodotRepo }
    AfterEach  { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    It '-EnableAddon appends [editor_plugins] once' {
        . $script:scriptPath -RepoRoot $script:tmp
        Mock Get-Process { $null }
        $pgPath = Join-Path $script:tmp 'project.godot'
        Enable-GodotAddon -ProjectGodotPath $pgPath | Out-Null
        Enable-GodotAddon -ProjectGodotPath $pgPath | Out-Null
        $pg = Get-Content -Raw $pgPath
        ([regex]::Matches($pg, [regex]::Escape('res://addons/godot_mcp_toolkit/plugin.cfg'))).Count | Should -Be 1
        ([regex]::Matches($pg, '(?m)^\[editor_plugins\]')).Count | Should -Be 1
        $pg | Should -Match '(?m)^enabled=PackedStringArray\([^)]*"res://addons/godot_mcp_toolkit/plugin\.cfg"[^)]*\)\s*$'
    }

    It 'end to end: the default run twice leaves one enable entry' -Skip:$script:godotRunning {
        Invoke-Prepare -Root $script:tmp | Out-Null
        Invoke-Prepare -Root $script:tmp | Out-Null
        $pg = Get-Content -Raw (Join-Path $script:tmp 'project.godot')
        ([regex]::Matches($pg, [regex]::Escape('res://addons/godot_mcp_toolkit/plugin.cfg'))).Count | Should -Be 1
        ([regex]::Matches($pg, '(?m)^\[editor_plugins\]')).Count | Should -Be 1
    }

    It 'merges into an existing PackedStringArray entry' {
        . $script:scriptPath -RepoRoot $script:tmp
        Mock Get-Process { $null }
        $pgPath = Join-Path $script:tmp 'project.godot'
        Add-Content -Path $pgPath -Value "`n[editor_plugins]`n`nenabled=PackedStringArray(`"res://addons/other/plugin.cfg`")`n"
        Enable-GodotAddon -ProjectGodotPath $pgPath | Out-Null
        $pg = Get-Content -Raw $pgPath
        $pg | Should -Match 'res://addons/other/plugin\.cfg'
        ([regex]::Matches($pg, [regex]::Escape('res://addons/godot_mcp_toolkit/plugin.cfg'))).Count | Should -Be 1
        ([regex]::Matches($pg, '(?m)^\[editor_plugins\]')).Count | Should -Be 1
        ([regex]::Matches($pg, '(?m)^enabled=')).Count | Should -Be 1
        $pg | Should -Match '(?m)^enabled=PackedStringArray\("res://addons/other/plugin\.cfg",\s*"res://addons/godot_mcp_toolkit/plugin\.cfg"\)\s*$'
    }

    It 'guard: leaves project.godot untouched and warns while a godot process runs' {
        . $script:scriptPath -RepoRoot $script:tmp
        Mock Get-Process { [pscustomobject]@{ Name = 'godot'; Id = 4242 } }
        $pgPath = Join-Path $script:tmp 'project.godot'
        $before = [System.IO.File]::ReadAllBytes($pgPath)
        Enable-GodotAddon -ProjectGodotPath $pgPath -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        [System.IO.File]::ReadAllBytes($pgPath) | Should -Be $before
        $w | Should -Not -BeNullOrEmpty
        Should -Invoke Get-Process -Times 1 -Exactly -Scope It
    }
}

Describe 'prepare-godot-worktree.ps1 A: addon install (ticket #4)' {
    BeforeAll {
        $script:zip104 = New-FixtureAddonZip -Version '1.0.4'
        $script:enableRx = '(?m)^enabled=PackedStringArray\([^)]*"res://addons/godot_mcp_toolkit/plugin\.cfg"[^)]*\)\s*$'
    }
    BeforeEach { $script:tmp = New-TempGodotRepo }
    AfterEach  { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

    # A1 - symptom: without the addon nothing binds a port (ECONNREFUSED 127.0.0.1:6550).
    It 'A1: default run on empty addons/ installs addon 1.0.4 and enables it' -Skip:$script:godotRunning {
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'addons') | Out-Null
        $r = Invoke-Prepare -Root $script:tmp
        $r.ExitCode | Should -Be 0
        $cfg = Join-Path $script:tmp 'addons/godot_mcp_toolkit/plugin.cfg'
        $cfg | Should -Exist
        (Get-Content -Raw $cfg) | Should -Match '(?m)^version="1\.0\.4"'
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit/plugin.gd') | Should -Exist
        $pg = Get-Content -Raw (Join-Path $script:tmp 'project.godot')
        $pg | Should -Match $script:enableRx
        ([regex]::Matches($pg, [regex]::Escape('res://addons/godot_mcp_toolkit/plugin.cfg'))).Count | Should -Be 1
    }

    It 'A1 (layout): a zip with a top-level folder installs identically' -Skip:$script:godotRunning {
        $zip = New-FixtureAddonZip -Version '1.0.4' -TopFolder
        $r = Invoke-Prepare -Root $script:tmp -AddonSource $zip
        $r.ExitCode | Should -Be 0
        (Get-Content -Raw (Join-Path $script:tmp 'addons/godot_mcp_toolkit/plugin.cfg')) | Should -Match '(?m)^version="1\.0\.4"'
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit/plugin.gd') | Should -Exist
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit/godot-mcp-toolkit-pkg') | Should -Not -Exist
    }

    # A2 - the addon at the right version is never touched, and the source is never resolved.
    It 'A2: a re-run with the addon at 1.0.4 changes nothing under the addon and never reads the source' -Skip:$script:godotRunning {
        Invoke-Prepare -Root $script:tmp | Out-Null
        $dir = Join-Path $script:tmp 'addons/godot_mcp_toolkit'
        $dir | Should -Exist
        $before = Get-TreeSnapshot $dir
        Start-Sleep -Milliseconds 1100
        $r = Invoke-Prepare -Root $script:tmp -AddonSource (Join-Path $script:tmp 'no-such-source.zip')
        $r.ExitCode | Should -Be 0
        Get-TreeSnapshot $dir | Should -Be $before
    }

    It 'A2 (content): a same-version zip with different content does not overwrite' -Skip:$script:godotRunning {
        Invoke-Prepare -Root $script:tmp | Out-Null
        $dir = Join-Path $script:tmp 'addons/godot_mcp_toolkit'
        $before = Get-TreeSnapshot $dir
        Start-Sleep -Milliseconds 1100
        $other = New-FixtureAddonZip -Version '1.0.4' -GdContent '# different content'
        (Invoke-Prepare -Root $script:tmp -AddonSource $other).ExitCode | Should -Be 0
        Get-TreeSnapshot $dir | Should -Be $before
    }

    # A3 - the default path (not just Enable-GodotAddon) must not edit project.godot under a running editor.
    It 'A3: while a godot process runs, files are installed but project.godot stays byte-identical, with a warning' {
        . $script:scriptPath -RepoRoot $script:tmp
        Mock Get-Process { [pscustomobject]@{ Name = 'godot'; Id = 4242 } }
        $pgPath = Join-Path $script:tmp 'project.godot'
        $before = [System.IO.File]::ReadAllBytes($pgPath)
        Initialize-GodotAddon -RepoRoot $script:tmp -Source $script:zip104 -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        [System.IO.File]::ReadAllBytes($pgPath) | Should -Be $before
        $w | Should -Not -BeNullOrEmpty
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit/plugin.cfg') | Should -Exist
    }

    # A4 - decision (plan-critic misread::F1): an addon at another version is never overwritten,
    # and it is NOT enabled either: enabling a version that does not match the pinned bridge is
    # the ticket's most common setup mistake. The user deletes the folder and re-runs to replace it.
    It 'A4: an addon at another version is left untouched, warned about (both versions named) and not enabled' {
        . $script:scriptPath -RepoRoot $script:tmp
        Mock Get-Process { $null }
        $old = New-FixtureAddonZip -Version '1.0.3'
        $dir = Join-Path $script:tmp 'addons/godot_mcp_toolkit'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null
        Expand-Archive -LiteralPath $old -DestinationPath $script:tmp
        $dir | Should -Exist
        $snap = Get-TreeSnapshot $dir
        $pgPath = Join-Path $script:tmp 'project.godot'
        $pgBefore = [System.IO.File]::ReadAllBytes($pgPath)

        Initialize-GodotAddon -RepoRoot $script:tmp -Source $script:zip104 -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        Get-TreeSnapshot $dir | Should -Be $snap
        ($w -join "`n") | Should -Match '1\.0\.3'
        ($w -join "`n") | Should -Match '1\.0\.4'
        [System.IO.File]::ReadAllBytes($pgPath) | Should -Be $pgBefore
    }

    # A5 - a wrong archive must not install silently (it would resurface as the same ECONNREFUSED).
    It 'A5: an archive whose plugin.cfg is not the pinned version throws and installs nothing' {
        . $script:scriptPath -RepoRoot $script:tmp
        $bad = New-FixtureAddonZip -Version '9.9.9'
        { Install-GodotAddon -RepoRoot $script:tmp -Source $bad } | Should -Throw '*9.9.9*'
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit') | Should -Not -Exist
    }

    It 'A5 (missing source): a local source path that does not exist throws without installing' {
        . $script:scriptPath -RepoRoot $script:tmp
        { Install-GodotAddon -RepoRoot $script:tmp -Source (Join-Path $script:tmp 'nope.zip') } | Should -Throw '*not found*'
        (Join-Path $script:tmp 'addons/godot_mcp_toolkit') | Should -Not -Exist
    }
}

# ---------------------------------------------------------------------------
# R6 - real editor, two environments, gui game_start. Run by hand, never in CI.
# ---------------------------------------------------------------------------
Describe 'Live: per-environment Godot editor' -Tag Live {
    BeforeAll {
        $script:liveReady = [bool]$env:GODOT_EDITOR_PATH -and [bool]$env:GODOT_LIVE_PROJECT
        if (-not $script:liveReady) { return }
        $script:liveMain = (Resolve-Path $env:GODOT_LIVE_PROJECT).Path
        $script:liveWt   = Join-Path ([System.IO.Path]::GetTempPath()) ('pgw-wt-' + [System.IO.Path]::GetRandomFileName())
        & git -C $script:liveMain worktree add --detach $script:liveWt | Out-Null
        # Ticket #4: the worktree starts as a fresh checkout with an EMPTY addons/ (no addon,
        # no [editor_plugins] enable entry); prepare must install (default = real release URL,
        # network) and enable the pinned addon before the editor can boot there.
        Remove-Item -Recurse -Force (Join-Path $script:liveWt 'addons/godot_mcp_toolkit') -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path (Join-Path $script:liveWt 'addons') | Out-Null
        $wtPg = Join-Path $script:liveWt 'project.godot'
        [System.IO.File]::WriteAllText($wtPg, ([regex]::Replace((Get-Content -Raw $wtPg),
            '(?m)^enabled=PackedStringArray\(.*\)[ \t]*\r?\n?', '')))
        foreach ($p in @($script:liveMain, $script:liveWt)) {
            & pwsh -NoProfile -File $script:scriptPath -RepoRoot $p | Out-Null
        }
        # Distinct application/config/name per checkout.
        $script:liveNames = @{}
        foreach ($p in @($script:liveMain, $script:liveWt)) {
            $n = 'live-' + [System.IO.Path]::GetRandomFileName().Replace('.', '')
            $pg = Join-Path $p 'project.godot'
            $c = Get-Content -Raw $pg
            $c = [regex]::Replace($c, '(?m)^config/name=.*$', "config/name=`"$n`"")
            [System.IO.File]::WriteAllText($pg, $c)
            $script:liveNames[$p] = $n
        }

        function Invoke-LiveStep {
            param([string]$Checkout, [string]$StepName, [string]$Section)
            $yml = Get-Content -Raw (Join-Path $Checkout '.seretos/worktree-setup.yml')
            $s = Get-YmlSections $yml
            $body = Get-RunBody $s[$Section] $StepName
            Invoke-StepBody -Body $body -WorktreePath $Checkout
        }

        # Minimal MCP stdio client against the pinned bridge; cwd = checkout, no
        # GODOT_MCP_PROJECT_PATH, so the bridge resolves the project via its cwd fallback.
        function Invoke-BridgeTool {
            param([string]$Checkout, [string]$Tool, [hashtable]$ToolArgs = @{})
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = if ($IsWindows) { 'npx.cmd' } else { 'npx' }
            foreach ($a in @('-y', '@npgamedev/godot-mcp-server@1.0.4')) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory = $Checkout
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
            $psi.Environment.Remove('GODOT_MCP_PROJECT_PATH') | Out-Null
            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $send = {
                    param($o) $proc.StandardInput.WriteLine(($o | ConvertTo-Json -Depth 8 -Compress)); $proc.StandardInput.Flush()
                }
                & $send @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'pester'; version = '0' } } }
                $null = $proc.StandardOutput.ReadLineAsync().Wait(60000)
                & $send @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
                & $send @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = $Tool; arguments = $ToolArgs } }
                $deadline = (Get-Date).AddSeconds(60)
                while ((Get-Date) -lt $deadline) {
                    $t = $proc.StandardOutput.ReadLineAsync()
                    if (-not $t.Wait(60000)) { break }
                    if ($t.Result -match '"id"\s*:\s*2') { return $t.Result }
                }
                return $null
            } finally { if (-not $proc.HasExited) { $proc.Kill($true) } }
        }
    }

    AfterAll {
        if (-not $script:liveReady) { return }
        foreach ($p in @($script:liveMain, $script:liveWt)) {
            Invoke-LiveStep -Checkout $p -StepName $null -Section 'Stop' | Out-Null
        }
        & git -C $script:liveMain worktree remove --force $script:liveWt 2>$null | Out-Null
        & git -C $script:liveMain checkout -- project.godot 2>$null | Out-Null
    }

    It 'boots a headless editor in each of two checkouts and each bridge sees its own project' -Skip:(-not ($env:GODOT_EDITOR_PATH -and $env:GODOT_LIVE_PROJECT)) {
        # The fresh worktree got its addon from prepare, not from the checkout.
        (Get-Content -Raw (Join-Path $script:liveWt 'addons/godot_mcp_toolkit/plugin.cfg')) | Should -Match '(?m)^version="1\.0\.4"'
        (Get-Content -Raw (Join-Path $script:liveWt 'project.godot')) | Should -Match 'res://addons/godot_mcp_toolkit/plugin\.cfg'
        foreach ($p in @($script:liveMain, $script:liveWt)) {
            $r = Invoke-LiveStep -Checkout $p -StepName 'default' -Section 'Start'
            $r.ExitCode | Should -Be 0
            (Get-Content -Raw (Join-Path $p '.godot-mcp/editor.log')) | Should -Match '\[MCPServer\] listening on 127\.0\.0\.1:\d+'
        }
        foreach ($p in @($script:liveMain, $script:liveWt)) {
            $resp = Invoke-BridgeTool -Checkout $p -Tool 'project_get_settings'
            $resp | Should -Match ([regex]::Escape($script:liveNames[$p]))
            foreach ($other in @($script:liveMain, $script:liveWt) | Where-Object { $_ -ne $p }) {
                $resp | Should -Not -Match ([regex]::Escape($script:liveNames[$other]))
            }
        }
    }

    It 'gui variant: game_start succeeds where headless gives HEADLESS_UNSUPPORTED' -Skip:(-not ($env:GODOT_EDITOR_PATH -and $env:GODOT_LIVE_PROJECT)) {
        $p = $script:liveMain
        Invoke-LiveStep -Checkout $p -StepName $null -Section 'Stop' | Out-Null
        (Invoke-LiveStep -Checkout $p -StepName 'default' -Section 'Start').ExitCode | Should -Be 0
        (Invoke-BridgeTool -Checkout $p -Tool 'game_start') | Should -Match 'HEADLESS_UNSUPPORTED'
        Invoke-LiveStep -Checkout $p -StepName $null -Section 'Stop' | Out-Null
        (Invoke-LiveStep -Checkout $p -StepName 'gui' -Section 'Start').ExitCode | Should -Be 0
        $guiResp = Invoke-BridgeTool -Checkout $p -Tool 'game_start'
        $guiResp | Should -Not -BeNullOrEmpty
        $guiResp | Should -Match '"result"'
        $guiResp | Should -Not -Match '"error"|"isError"\s*:\s*true|HEADLESS_UNSUPPORTED'
        Invoke-BridgeTool -Checkout $p -Tool 'game_stop' | Out-Null
    }
}
