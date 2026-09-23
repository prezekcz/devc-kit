<#
  devc-gui.ps1 - WinForms launcher for devc podman dev containers.

  Shows every devc-* container - local and on connected remote servers - in one
  table and offers start / stop / restart / shell / VS Code / logs / remove over
  it. A thin GUI over the existing scripts: state is read directly (podman REST
  for remote tunnels, podman CLI for local), the odd, well-tuned actions
  (VS Code attach) are delegated to devc-code.ps1 / devc.ps1 unchanged.

  Reads run on a runspace pool so the window never blocks on a slow/dead tunnel.

  Run visibly while developing:
      powershell -ExecutionPolicy Bypass -File .\devc-gui.ps1
  Pinned shortcut launches it hidden (Tools -> Pin to taskbar).

  Windows PowerShell 5.1, STA. No PS 7+ syntax.
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ListView column sorter (§4, optional). Compares the clicked column's text;
# numeric-aware so ports/states sort sensibly enough.
if (-not ('DevcColumnSorter' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections;
using System.Windows.Forms;

public class DevcColumnSorter : IComparer {
    private int col;
    private bool asc;
    public DevcColumnSorter(int column, bool ascending) { col = column; asc = ascending; }
    public int Compare(object x, object y) {
        var a = ((ListViewItem)x).SubItems[col].Text;
        var b = ((ListViewItem)y).SubItems[col].Text;
        int r = String.Compare(a, b, StringComparison.OrdinalIgnoreCase);
        return asc ? r : -r;
    }
}
'@
}

# ===========================================================================
# Log (%LOCALAPPDATA%\devc\devc-gui.log), to find out afterwards what was done
# and what went wrong: every click with the row it acted on, every status line,
# each background job with its duration and failure, launched processes, and
# unexpected exceptions. Written from the UI thread only (workers report through
# their results), so no locking. Never log passwords. Rolls over to .1 at 1 MB.
# ===========================================================================
$logDir = $env:LOCALAPPDATA
if (-not $logDir) { $logDir = $env:TEMP }
$script:LogPath = Join-Path $logDir 'devc\devc-gui.log'
try {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $script:LogPath))
    if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) {
        Move-Item -Force $script:LogPath "$script:LogPath.1"
    }
} catch { }

function Write-DevcLog {
    param([string]$Tag, [string]$Text)
    $line = '{0} {1,5} [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Tag, $Text
    try { [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine) } catch { }
}

$rev = ''
if (Get-Command git -ErrorAction SilentlyContinue) {
    try { $rev = (& git -C $PSScriptRoot rev-parse --short HEAD 2>$null) } catch { }
}
Write-DevcLog 'start' ("{0} {1}, PS {2}, {3}, host {4}" -f $PSCommandPath, $rev,
    $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString, $Host.Name)

# Unhandled UI-thread exceptions. When the host pipeline is stopped while the
# window is up (VS Code Stop / Ctrl+C), ShowDialog keeps pumping and the next
# scriptblock handler (Pump tick) throws PipelineStoppedException into WinForms,
# which would show its crash dialog. Rethrow that one so ShowDialog unwinds into
# the finally below; anything else gets a plain message box and the GUI lives on.
# C#, because a scriptblock handler can't run once the pipeline is stopped.
#
# A type can't be redefined in a running session (VS Code's PowerShell console
# keeps it between runs), so the class name carries a hash of its source: after
# an edit the new version loads under a fresh name instead of the stale one.
$guardSrc = @'
using System;
using System.IO;
using System.Management.Automation;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows.Forms;

public static class DevcUiGuard {
    private static bool installed;
    public static string LogPath;
    public static void Install(string logPath) {
        LogPath = logPath;
        if (installed) return;
        installed = true;
        Application.ThreadException += OnThreadException;
    }
    private static void Log(string text) {
        try {
            File.AppendAllText(LogPath, String.Format("{0:yyyy-MM-dd HH:mm:ss.fff} {1,5} [crash] {2}{3}",
                DateTime.Now, System.Diagnostics.Process.GetCurrentProcess().Id, text, Environment.NewLine));
        } catch { }
    }
    private static void OnThreadException(object sender, ThreadExceptionEventArgs e) {
        if (e.Exception is PipelineStoppedException) {
            Log("pipeline stopped while the window was up - shutting down");
            ExceptionDispatchInfo.Capture(e.Exception).Throw();
        }
        Log(e.Exception.ToString());
        MessageBox.Show(e.Exception.Message, "devc - unexpected error",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
'@
$guardHash = -join ([System.Security.Cryptography.SHA1]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($guardSrc))[0..3] | ForEach-Object { $_.ToString('x2') })
$guardName = "DevcUiGuard_$guardHash"
if (-not ($guardName -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms `
        -TypeDefinition ($guardSrc -replace 'class DevcUiGuard\b', "class $guardName")
}
($guardName -as [type])::Install($script:LogPath)

# Data / action layer, shared with the worker runspaces (§7). Dot-source it here
# for the UI-thread calls; each worker dot-sources it again for its own scope.
$script:LibPath  = Join-Path $PSScriptRoot 'devc-gui.lib.ps1'
$script:DevcCode = Join-Path $PSScriptRoot 'devc-code.ps1'
$script:DevcPs1  = Join-Path $PSScriptRoot 'devc.ps1'
. $script:LibPath

# ===========================================================================
# Async plumbing: runspace pool + a WinForms timer that reaps finished jobs on
# the UI thread (§7). Workers return data only; OnDone (UI thread) touches WinForms.
# ===========================================================================
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 4)
$script:Pool.Open()
$script:Pending = New-Object System.Collections.ArrayList
$script:BusyCount = 0

function Start-Async {
    param([scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone, [string]$Label)
    # label for the log; defaults to the calling function (Invoke-Lifecycle, ...)
    if (-not $Label) { $Label = (Get-PSCallStack)[1].Command }
    Write-DevcLog 'job' "start $Label"
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Work)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$script:Pending.Add([pscustomobject]@{
        PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone
        Label = $Label; Watch = [System.Diagnostics.Stopwatch]::StartNew()
    })
}

# ===========================================================================
# Window
# ===========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'devc container manager'
$form.Size = New-Object System.Drawing.Size(1000, 600)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(780, 440)
$iconPath = Join-Path $PSScriptRoot 'devc-gui.ico'
if (Test-Path $iconPath) { $form.Icon = [System.Drawing.Icon]::new($iconPath) }

# --- menu (Tools -> Pin to taskbar) ---
$menu = New-Object System.Windows.Forms.MenuStrip
$mnuTools = New-Object System.Windows.Forms.ToolStripMenuItem('Tools')
$mnuPin   = New-Object System.Windows.Forms.ToolStripMenuItem('Pin to taskbar')
$mnuBuild = New-Object System.Windows.Forms.ToolStripMenuItem('Build base image...')
$mnuLog   = New-Object System.Windows.Forms.ToolStripMenuItem('Open log')
[void]$mnuTools.DropDownItems.Add($mnuPin)
[void]$mnuTools.DropDownItems.Add($mnuBuild)
[void]$mnuTools.DropDownItems.Add($mnuLog)
[void]$menu.Items.Add($mnuTools)
$form.MainMenuStrip = $menu

# --- top toolbar row ---
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(10, 30)
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$btnRefresh.Anchor = 'Top,Left'

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Connect server...'
$btnConnect.Location = New-Object System.Drawing.Point(108, 30)
$btnConnect.Size = New-Object System.Drawing.Size(130, 28)
$btnConnect.Anchor = 'Top,Left'

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = 'Disconnect'
$btnDisconnect.Location = New-Object System.Drawing.Point(246, 30)
$btnDisconnect.Size = New-Object System.Drawing.Size(100, 28)
$btnDisconnect.Anchor = 'Top,Left'

# --- filter box (right side of the toolbar) ---
$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Filter:'
$lblSearch.Location = New-Object System.Drawing.Point(690, 35)
$lblSearch.Size = New-Object System.Drawing.Size(44, 20)
$lblSearch.TextAlign = 'MiddleRight'
$lblSearch.Anchor = 'Top,Right'

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(738, 32)
$txtSearch.Size = New-Object System.Drawing.Size(236, 24)
$txtSearch.Anchor = 'Top,Right'

# --- container table ---
$listView = New-Object System.Windows.Forms.ListView
$listView.View = 'Details'
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.MultiSelect = $false
$listView.HideSelection = $false
$listView.Location = New-Object System.Drawing.Point(10, 66)
$listView.Size = New-Object System.Drawing.Size(964, 428)
$listView.Anchor = 'Top,Bottom,Left,Right'
[void]$listView.Columns.Add('Project', 150)
[void]$listView.Columns.Add('Container', 230)
[void]$listView.Columns.Add('Location', 120)
[void]$listView.Columns.Add('State', 80)
[void]$listView.Columns.Add('Image', 130)
[void]$listView.Columns.Add('Path', 230)

# --- right-click menu on a row (open / copy the project path) ---
$rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem('Open containing folder')
$miCopyPath   = New-Object System.Windows.Forms.ToolStripMenuItem('Copy path')
$miCopyName   = New-Object System.Windows.Forms.ToolStripMenuItem('Copy container name')
[void]$rowMenu.Items.Add($miOpenFolder)
[void]$rowMenu.Items.Add($miCopyPath)
[void]$rowMenu.Items.Add($miCopyName)
$listView.ContextMenuStrip = $rowMenu

# --- status bar ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'starting...'
[void]$statusStrip.Items.Add($statusLabel)

# --- action buttons (bottom right) ---
function New-ActionButton {
    param([string]$Text, [int]$X)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size(84, 32)
    $b.Location = New-Object System.Drawing.Point($X, 500)
    $b.Anchor = 'Bottom,Right'
    $b
}
# 7 buttons x 84 + 4px gaps, ending ~10px inside the client right edge (client ~984)
$btnStart   = New-ActionButton 'Start'   362
$btnStop    = New-ActionButton 'Stop'    450
$btnRestart = New-ActionButton 'Restart' 538
$btnShell   = New-ActionButton 'Shell'   626
$btnLogs    = New-ActionButton 'Logs'    714
$btnCode    = New-ActionButton 'VS Code' 802
$btnRemove  = New-ActionButton 'Remove'  890

$form.Controls.AddRange(@(
    $btnRefresh, $btnConnect, $btnDisconnect, $lblSearch, $txtSearch,
    $listView, $statusStrip,
    $btnStart, $btnStop, $btnRestart, $btnShell, $btnLogs, $btnCode, $btnRemove,
    $menu
))

# ===========================================================================
# Status + row helpers (all UI thread)
# ===========================================================================
function Set-Status {
    param([string]$Text, [switch]$NoLog)
    $statusLabel.Text = $Text
    if (-not $NoLog) { Write-DevcLog 'status' $Text }
}

# log a user action together with the row it acts on
function Write-DevcAction {
    param([string]$Action)
    $row = Get-SelectedRow
    $on = ''
    if ($row) { $on = " $($row.Name) @ $($row.Location) [$($row.State)]" }
    Write-DevcLog 'click' "$Action$on"
}

function Get-SelectedRow {
    if ($listView.SelectedItems.Count -eq 0) { return $null }
    $listView.SelectedItems[0].Tag
}

# Full set of rows gathered by the last refresh; the ListView shows the subset
# that matches the filter box (§ search). $script:AllRows is reset per refresh.
$script:AllRows = New-Object System.Collections.ArrayList

# Does a row match the current filter text? (case-insensitive substring on any
# visible field). Empty filter matches everything.
function Test-RowMatch {
    param([pscustomobject]$Row)
    $f = "$($txtSearch.Text)".Trim()
    if (-not $f) { return $true }
    $hay = @($Row.Project, $Row.Name, $Row.Location, $Row.State, $Row.Image, $Row.Path) -join ' '
    return ($hay -like "*$f*")
}

# Build and append the ListViewItem for one row (no filtering / collecting here).
function Add-RowItem {
    param([pscustomobject]$Row)
    $item = New-Object System.Windows.Forms.ListViewItem([string]$Row.Project)
    [void]$item.SubItems.Add([string]$Row.Name)
    [void]$item.SubItems.Add([string]$Row.Location)
    [void]$item.SubItems.Add([string]$Row.State)
    [void]$item.SubItems.Add([string]$Row.Image)
    [void]$item.SubItems.Add([string]$Row.Path)
    $item.Tag = $Row      # whole object, so handlers never parse column text (§4)
    switch -Regex ($Row.State) {
        'running'        { $item.ForeColor = [System.Drawing.Color]::ForestGreen }
        'exited|created' { $item.ForeColor = [System.Drawing.Color]::Gray }
        default          { }
    }
    [void]$listView.Items.Add($item)
}

# Collect a row (from a refresh worker) and show it if it passes the filter.
function Add-ContainerRow {
    param([pscustomobject]$Row)
    [void]$script:AllRows.Add($Row)
    if (Test-RowMatch $Row) { Add-RowItem $Row }
}

# Re-render the ListView from $script:AllRows for the current filter (called as
# the user types). Preserves nothing else - selection is rebuilt by the user.
function Update-RowFilter {
    $listView.BeginUpdate()
    $listView.Items.Clear()
    foreach ($r in @($script:AllRows)) { if (Test-RowMatch $r) { Add-RowItem $r } }
    $listView.EndUpdate()
    Update-ButtonState
    $shown = $listView.Items.Count
    $total = $script:AllRows.Count
    if ("$($txtSearch.Text)".Trim()) { Set-Status "filter: $shown / $total shown" -NoLog }
}

# enable only the buttons that make sense for the selected row's state (§4)
function Update-ButtonState {
    $row = Get-SelectedRow
    $has = $null -ne $row
    $running = $has -and ($row.State -match 'running')
    $exited  = $has -and ($row.State -match 'exited|created|configured')
    $btnStart.Enabled   = $exited
    $btnStop.Enabled    = $running
    $btnRestart.Enabled = $running
    $btnShell.Enabled   = $running
    $btnCode.Enabled    = $running
    $btnLogs.Enabled    = $has
    $btnRemove.Enabled  = $has
}

function Set-Busy {
    param([bool]$On)
    if ($On) {
        $script:BusyCount++
    } else {
        if ($script:BusyCount -gt 0) { $script:BusyCount-- }
    }
    $busy = $script:BusyCount -gt 0
    if ($busy) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else       { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $btnRefresh.Enabled = -not $busy
}

# ===========================================================================
# Refresh: one job per server + one for local, results drawn as they arrive (§7)
# ===========================================================================
function Invoke-Refresh {
    if ($script:BusyCount -gt 0) { return }   # don't stack refreshes
    $script:AllRows.Clear()
    $listView.BeginUpdate()
    $listView.Items.Clear()
    $listView.EndUpdate()
    Update-ButtonState

    $tunnels = @(Get-DevcTunnels)
    Set-Status ("refreshing: local + {0} server(s)..." -f $tunnels.Count)
    Set-Busy $true

    $script:RefreshTotal = $tunnels.Count + 1   # +1 for local
    $script:RefreshDone = 0
    $script:RefreshCount = 0
    $script:RefreshDead = @()

    $onServerDone = {
        param($snap)
        if ($snap -and $snap.Ok) {
            foreach ($r in @($snap.Rows)) { Add-ContainerRow $r; $script:RefreshCount++ }
        } elseif ($snap) {
            # §8.2: port listens but forwards nowhere -> mark unresponsive, kill
            # the dead ssh, offer reconnect. Don't let it block the others.
            $script:RefreshDead += $snap.Server
            [void](Disconnect-DevcTunnel -Server $snap.Server)
            $ghost = [pscustomobject]@{
                Server = $snap.Server; Location = (Get-DevcLocationLabel $snap.Server)
                IsLocal = $false; Url = $null; Port = $snap.Port; Name = '(tunnel torn down)'
                Project = $snap.Server; State = 'unresponsive'; Image = ''; Path = $snap.Error
            }
            Add-ContainerRow $ghost
        }
        Complete-RefreshStep
    }

    foreach ($t in $tunnels) {
        $work = {
            param($libPath, $server, $port)
            . $libPath
            Get-DevcServerSnapshot -Server $server -Port $port -TimeoutSec 5
        }
        Start-Async -Work $work -Arguments @($script:LibPath, $t.Server, $t.Port) -OnDone $onServerDone `
            -Label "refresh $($t.Server):$($t.Port)"
    }

    # local
    $localWork = {
        param($libPath)
        . $libPath
        Get-DevcContainersLocal
    }
    Start-Async -Work $localWork -Arguments @($script:LibPath) -Label 'refresh local' -OnDone {
        param($res)
        if ($res -and $res.Ok) {
            foreach ($r in @($res.Rows)) { Add-ContainerRow $r; $script:RefreshCount++ }
        } elseif ($res) {
            Set-Status "local: $($res.Error)"
        }
        Complete-RefreshStep
    }
}

function Complete-RefreshStep {
    $script:RefreshDone++
    if ($script:RefreshDone -ge $script:RefreshTotal) {
        Set-Busy $false
        Update-ButtonState
        # server count from the refresh itself: re-running Get-DevcTunnels here
        # (a CIM process query) froze the window for ~0.75 s
        $servers = $script:RefreshTotal - 1 - $script:RefreshDead.Count
        $msg = "{0} container(s) on {1} server(s)" -f $script:RefreshCount, $servers
        if ($script:RefreshDead.Count -gt 0) {
            $msg += " - unresponsive (torn down): $($script:RefreshDead -join ', ')"
        }
        Set-Status $msg
    }
}

# ===========================================================================
# Child-process launch helper: scope CONTAINER_HOST to the child only (§8.3).
# Never mutate this long-lived process's own env.
# ===========================================================================
# ProcessStartInfo.ArgumentList exists on .NET 4.6+ (PS 5.1 on current Windows);
# fall back to a quoted string if it's somehow unavailable. Env vars are set on
# the child only (§8.3) - this long-lived process's own env is never mutated.
function Start-DevcProcessCompat {
    param(
        [string]$FilePath, [string[]]$Arguments, [string]$ContainerHost,
        [switch]$Hidden, [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $hasList = $psi.PSObject.Properties.Name -contains 'ArgumentList'
    if ($hasList) {
        foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = ($Arguments | ForEach-Object {
            if ("$_" -match '\s|"') { '"{0}"' -f ("$_" -replace '"', '\"') } else { "$_" }
        }) -join ' '
    }
    $psi.UseShellExecute = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Hidden) {
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
    }
    if ($ContainerHost) {
        $psi.EnvironmentVariables['CONTAINER_HOST'] = $ContainerHost
        $psi.EnvironmentVariables['DOCKER_HOST']    = $ContainerHost
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $envNote = ''
    if ($ContainerHost) { $envNote = " (CONTAINER_HOST=$ContainerHost)" }
    Write-DevcLog 'exec' ("pid {0}: {1} {2}{3}" -f $p.Id, $FilePath, ($Arguments -join ' '), $envNote)
    $p
}

# ===========================================================================
# Actions
# ===========================================================================

# start / stop / restart via REST(remote)/CLI(local), async, then refresh (§6)
function Invoke-Lifecycle {
    param([string]$Action)
    $row = Get-SelectedRow
    if (-not $row) { return }
    Set-Status "$Action $($row.Name) on $($row.Location)..."
    Set-Busy $true
    $work = {
        param($libPath, $row, $action)
        . $libPath
        try { Invoke-DevcLifecycle -Row $row -Action $action; [pscustomobject]@{ Ok = $true; Error = $null } }
        catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    }
    Start-Async -Work $work -Arguments @($script:LibPath, $row, $Action) -OnDone {
        param($res)
        Set-Busy $false
        if ($res -and -not $res.Ok) { Set-Status "error: $($res.Error)" }
        else { Set-Status 'done' }
        Invoke-Refresh
    }
}

function Invoke-Remove {
    $row = Get-SelectedRow
    if (-not $row) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Remove container`n`n    $($row.Name)`n`non $($row.Location)?`n`nThis deletes the container (the project files on the mount are NOT touched).",
        'Confirm remove',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Status "removing $($row.Name)..."
    Set-Busy $true
    $work = {
        param($libPath, $row)
        . $libPath
        try { Remove-DevcContainer -Row $row; [pscustomobject]@{ Ok = $true; Error = $null } }
        catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    }
    Start-Async -Work $work -Arguments @($script:LibPath, $row) -OnDone {
        param($res)
        Set-Busy $false
        if ($res -and -not $res.Ok) { Set-Status "error: $($res.Error)" }
        else { Set-Status 'removed' }
        Invoke-Refresh
    }
}

# Right-click actions: open / copy the project path, copy the container name.
function Open-DevcFolder {
    $row = Get-SelectedRow
    if (-not $row) { return }
    if (-not $row.Path) { Set-Status "no project path known for $($row.Name)"; return }
    $win = ConvertTo-DevcWindowsPath $row.Path
    if (-not $win) { Set-Status "path is on a remote server, can't open locally: $($row.Path)"; return }
    if (-not (Test-Path $win)) { Set-Status "folder not found: $win"; return }
    Start-Process explorer.exe $win
    Set-Status "opened $win"
}

function Copy-DevcPath {
    $row = Get-SelectedRow
    if (-not $row -or -not $row.Path) { Set-Status 'no path to copy'; return }
    $win = ConvertTo-DevcWindowsPath $row.Path
    $text = if ($win) { $win } else { $row.Path }
    [System.Windows.Forms.Clipboard]::SetText($text)
    Set-Status "copied path: $text"
}

function Copy-DevcName {
    $row = Get-SelectedRow
    if (-not $row) { return }
    [System.Windows.Forms.Clipboard]::SetText($row.Name)
    Set-Status "copied name: $($row.Name)"
}

# Shell: new visible terminal (this GUI process has no console). wt.exe if present.
function Invoke-Shell {
    $row = Get-SelectedRow
    if (-not $row) { return }
    $inner = "podman exec -it $($row.Name) bash"
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($row.IsLocal) {
        if ($wt) { Start-DevcProcessCompat -FilePath $wt.Source -Arguments @('powershell', '-NoExit', '-Command', $inner) }
        else     { Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments @('-NoExit', '-Command', $inner) }
    } else {
        # CONTAINER_HOST must reach the child only (§8.3); pass it via the child env.
        if ($wt) { Start-DevcProcessCompat -FilePath $wt.Source -Arguments @('powershell', '-NoExit', '-Command', $inner) -ContainerHost $row.Url }
        else     { Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments @('-NoExit', '-Command', $inner) -ContainerHost $row.Url }
    }
    Set-Status "opened shell for $($row.Name)"
}

# VS Code attach: delegate to the odd, well-tuned scripts (§6.2). Visible so the
# user sees progress / a possible password prompt. Disable the button while it runs.
function Invoke-VsCode {
    param([switch]$Focus)   # -Focus -> devc-code.ps1 -NoClean (don't drop an attached window, §6.3)
    $row = Get-SelectedRow
    if (-not $row) { return }
    $btnCode.Enabled = $false
    try {
        if ($row.IsLocal) {
            # Attach straight to the known container by name - the same hex folder
            # URI devc.ps1:130-131 builds (§6.2 blesses this five-line duplicate).
            # This avoids relying on cwd/path, so it can never target the wrong
            # container. The row is only enabled when running, so no start needed.
            $hex = (([System.Text.Encoding]::ASCII.GetBytes($row.Name) |
                ForEach-Object { $_.ToString('x2') }) -join '')
            $uri = "vscode-remote://attached-container+$hex/workspace"
            # via powershell so the `code` cmd-shim resolves from PATH; hidden so
            # there's no console flash (code returns immediately).
            [void](Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-Command', "code --folder-uri `"$uri`""
            ) -Hidden)
            Set-Status "opening VS Code (local) for $($row.Name)"
        } else {
            $codeArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DevcCode,
                '-Server', $row.Server, '-Container', $row.Name
            )
            if ($Focus) { $codeArgs += '-NoClean' }
            [void](Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments $codeArgs)
            Set-Status "attaching VS Code to $($row.Name) on $($row.Location) - watch the console window"
        }
    } finally {
        $btnCode.Enabled = $true
        Update-ButtonState
    }
}

# Logs -> read-only text window
function Show-Logs {
    $row = Get-SelectedRow
    if (-not $row) { return }
    Set-Status "fetching logs for $($row.Name)..."
    Set-Busy $true
    $work = {
        param($libPath, $row)
        . $libPath
        # Carry the name in the result: OnDone runs from the pump's scope and
        # can't see this function's $row, so everything it needs must be in $res.
        try { [pscustomobject]@{ Ok = $true; Name = $row.Name; Text = (Get-DevcLogs -Row $row -Tail 200); Error = $null } }
        catch { [pscustomobject]@{ Ok = $false; Name = $row.Name; Text = ''; Error = $_.Exception.Message } }
    }
    Start-Async -Work $work -Arguments @($script:LibPath, $row) -OnDone {
        param($res)
        Set-Busy $false
        if (-not $res) { Set-Status 'logs: no result'; return }
        if (-not $res.Ok) { Set-Status "logs error: $($res.Error)"; return }
        Set-Status 'logs loaded'
        Show-LogWindow -Title "logs: $($res.Name)" -Text $res.Text
    }
}

function Show-LogWindow {
    param([string]$Title, [string]$Text)
    $w = New-Object System.Windows.Forms.Form
    $w.Text = $Title
    $w.Size = New-Object System.Drawing.Size(820, 560)
    $w.StartPosition = 'CenterParent'
    if (Test-Path $iconPath) { $w.Icon = [System.Drawing.Icon]::new($iconPath) }
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Both'
    $tb.WordWrap = $false
    $tb.Dock = 'Fill'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    if ([string]::IsNullOrEmpty($Text)) { $tb.Text = '(no output)' } else { $tb.Text = $Text }
    $w.Controls.Add($tb)
    [void]$w.Show($form)
}

# Connect server (§8.5/§8.6)
function Invoke-Connect {
    $known = @(Get-DevcKnownServers)
    $srv = Show-InputDialog -Title 'Connect server' -Prompt 'ssh target (user@host / host / alias):' -Items $known
    if (-not $srv) { return }
    $srv = "$srv".Trim()
    if (-not $srv) { return }

    Set-Status "connecting to $srv - checking key auth..."
    Set-Busy $true
    $work = {
        param($libPath, $server)
        . $libPath
        # Carry $server back in the result: OnDone runs from the pump's scope and
        # cannot see this function's $srv, so the server it needs to launch
        # devc-code.ps1 with must travel in $res (else -Server gets no value).
        try {
            $t = Connect-DevcTunnel -Server $server
            [pscustomobject]@{ Ok = $true; NeedsPassword = $false; Server = $server; Port = $t.Port; Reused = $t.Reused; Error = $null }
        } catch {
            $msg = "$($_.Exception.Message)"
            if ($msg -match 'key auth not available') {
                # pull out ssh's own reason (after '::') for the status bar
                $reason = $msg
                if ($msg -match '::\s*(.+)$') { $reason = $Matches[1].Trim() }
                [pscustomobject]@{ Ok = $false; NeedsPassword = $true; Server = $server; Port = 0; Reused = $false; Error = $reason }
            } else {
                [pscustomobject]@{ Ok = $false; NeedsPassword = $false; Server = $server; Port = 0; Reused = $false; Error = $msg }
            }
        }
    }
    Start-Async -Work $work -Arguments @($script:LibPath, $srv) -OnDone {
        param($res)
        Set-Busy $false
        if (-not $res) { Set-Status 'connect: no result'; return }
        if ($res.Ok) {
            Set-Status "connected to $($res.Server) on port $($res.Port)$(if ($res.Reused) { ' (reused)' })"
            Invoke-Refresh
            return
        }
        if ($res.NeedsPassword) {
            Set-Status "key auth to $($res.Server) failed: $($res.Error)"
            Connect-WithPassword -Server $res.Server -Reason $res.Error
        } else {
            Set-Status "connect error: $($res.Error)"
        }
    }
}

# Password server (§8.6): ask for the password in the GUI, bring the tunnel up
# hidden via SSH_ASKPASS. Only if that fails do we fall back to the visible
# devc-code.ps1 console (old OpenSSH, wrong password, askpass ignored).
function Connect-WithPassword {
    param([string]$Server, [string]$Reason)
    $pw = Show-PasswordDialog -Server $Server -Reason $Reason
    if (-not $pw) { Set-Status "connect to $Server cancelled"; return }
    Set-Status "connecting to $Server with password..."
    Set-Busy $true
    $work = {
        param($libPath, $server, $password)
        . $libPath
        try {
            $exe = New-DevcAskPassExe
            $t = Connect-DevcTunnelPassword -Server $server -Password $password -AskPassExe $exe
            [pscustomobject]@{ Ok = $true; Server = $server; Port = $t.Port; Error = $null }
        } catch {
            [pscustomobject]@{ Ok = $false; Server = $server; Port = 0; Error = $_.Exception.Message }
        }
    }
    Start-Async -Work $work -Arguments @($script:LibPath, $Server, $pw) -OnDone {
        param($r2)
        Set-Busy $false
        if ($r2 -and $r2.Ok) {
            Set-Status "connected to $($r2.Server) on port $($r2.Port)"
            Invoke-Refresh
            return
        }
        # fall back to the visible console the brief describes.
        $emsg = 'no result'; $srv = ''
        if ($r2) { $emsg = $r2.Error; $srv = $r2.Server }
        Set-Status "GUI password connect failed ($emsg) - opening a console; type the password there, then Refresh."
        [void](Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DevcCode, '-Server', $srv
        ))
    }
    $pw = $null   # drop our reference; the worker holds its own copy
}

function Invoke-Disconnect {
    $tunnels = @(Get-DevcTunnels)
    if ($tunnels.Count -eq 0) { Set-Status 'no servers connected'; return }
    $servers = @($tunnels | ForEach-Object { $_.Server } | Select-Object -Unique)
    $srv = Show-InputDialog -Title 'Disconnect server' -Prompt 'server to disconnect:' -Items $servers -MustPick
    if (-not $srv) { return }
    $n = Disconnect-DevcTunnel -Server $srv
    Set-Status "disconnected $srv ($n tunnel(s))"
    Invoke-Refresh
}

function Invoke-Build {
    # devc.ps1 build in a visible window - runs for minutes, streams output (§3).
    Start-DevcProcessCompat -FilePath 'powershell.exe' -Arguments @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DevcPs1, 'build'
    )
    Set-Status 'building base image in a console window...'
}

# ===========================================================================
# Small input dialog (combo of known values, editable) - used by Connect/Disconnect
# ===========================================================================
function Show-InputDialog {
    param([string]$Title, [string]$Prompt, [string[]]$Items, [switch]$MustPick)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(420, 170)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    if (Test-Path $iconPath) { $dlg.Icon = [System.Drawing.Icon]::new($iconPath) }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(12, 15)
    $lbl.Size = New-Object System.Drawing.Size(380, 20)

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = New-Object System.Drawing.Point(12, 40)
    $cmb.Size = New-Object System.Drawing.Size(380, 24)
    if ($MustPick) { $cmb.DropDownStyle = 'DropDownList' } else { $cmb.DropDownStyle = 'DropDown' }
    foreach ($it in @($Items)) { if ($it) { [void]$cmb.Items.Add($it) } }
    if ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = 0 }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(226, 85); $ok.Size = New-Object System.Drawing.Size(75, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(317, 85); $cancel.Size = New-Object System.Drawing.Size(75, 28)

    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($lbl, $cmb, $ok, $cancel))
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $cmb.Text }
    return $null
}

# Masked password prompt for the askpass path (§8.6). Returns the text or $null.
function Show-PasswordDialog {
    param([string]$Server, [string]$Reason)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Server password'
    $dlg.Size = New-Object System.Drawing.Size(440, 200)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    if (Test-Path $iconPath) { $dlg.Icon = [System.Drawing.Icon]::new($iconPath) }

    # why the key path didn't take (so a key-only server's failure is visible here)
    $lblWhy = New-Object System.Windows.Forms.Label
    $lblWhy.Location = New-Object System.Drawing.Point(12, 10)
    $lblWhy.Size = New-Object System.Drawing.Size(410, 34)
    $lblWhy.ForeColor = [System.Drawing.Color]::Firebrick
    if ($Reason) { $lblWhy.Text = "Key auth didn't take: $Reason" } else { $lblWhy.Text = '' }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "SSH password for $Server :"
    $lbl.Location = New-Object System.Drawing.Point(12, 48)
    $lbl.Size = New-Object System.Drawing.Size(410, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(12, 70)
    $txt.Size = New-Object System.Drawing.Size(410, 24)
    $txt.UseSystemPasswordChar = $true

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Connect'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(256, 115); $ok.Size = New-Object System.Drawing.Size(75, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(347, 115); $cancel.Size = New-Object System.Drawing.Size(75, 28)

    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($lblWhy, $lbl, $txt, $ok, $cancel))
    [void]$dlg.Add_Shown({ $txt.Focus() })
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $txt.Text }
    return $null
}

# ===========================================================================
# Pin to taskbar (adapted from ComPortLauncher.ps1; §9 improvements: menu item,
# no (2).lnk duplicate - overwrite if the target already matches).
# ===========================================================================
function Pin-ToTaskbar {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        [void][System.Windows.Forms.MessageBox]::Show('Cannot determine script path. Save the script to a file first.', 'Error')
        return
    }
    $dir = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    $lnkPath = Join-Path $dir 'devc containers.lnk'
    $target = 'powershell.exe'
    $arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $ico = Join-Path (Split-Path $scriptPath) 'devc-gui.ico'

    $wsh = New-Object -ComObject WScript.Shell
    # §9: overwrite an existing shortcut with the same target instead of leaving a
    # "... (2).lnk" duplicate. CreateShortcut on an existing path just opens it.
    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $target
    $lnk.Arguments        = $arguments
    $lnk.WorkingDirectory = Split-Path $scriptPath
    $lnk.WindowStyle      = 1
    $lnk.Description       = 'devc container manager'
    if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" } else { $lnk.IconLocation = 'powershell.exe,0' }
    $lnk.Save()

    [void][System.Windows.Forms.MessageBox]::Show(
        "Shortcut created at:`n$lnkPath`n`nRight-click it on the taskbar to pin (or drag it there).",
        'Pin to taskbar')
    Start-Process explorer.exe (Split-Path $lnkPath)
}

# ===========================================================================
# Wire up events
# ===========================================================================
$btnRefresh.Add_Click({ Write-DevcAction 'refresh'; Invoke-Refresh })
$btnConnect.Add_Click({ Write-DevcAction 'connect'; Invoke-Connect })
$btnDisconnect.Add_Click({ Write-DevcAction 'disconnect'; Invoke-Disconnect })
$btnStart.Add_Click({ Write-DevcAction 'start'; Invoke-Lifecycle 'start' })
$btnStop.Add_Click({ Write-DevcAction 'stop'; Invoke-Lifecycle 'stop' })
$btnRestart.Add_Click({ Write-DevcAction 'restart'; Invoke-Lifecycle 'restart' })
$btnShell.Add_Click({ Write-DevcAction 'shell'; Invoke-Shell })
$btnLogs.Add_Click({ Write-DevcAction 'logs'; Show-Logs })
$btnCode.Add_Click({ Write-DevcAction 'vscode'; Invoke-VsCode })
$btnRemove.Add_Click({ Write-DevcAction 'remove'; Invoke-Remove })
$mnuPin.Add_Click({ Write-DevcAction 'pin to taskbar'; Pin-ToTaskbar })
$mnuBuild.Add_Click({ Write-DevcAction 'build image'; Invoke-Build })
$mnuLog.Add_Click({
    if (Test-Path $script:LogPath) { Start-Process notepad.exe $script:LogPath }
    else { Set-Status "no log yet: $script:LogPath" -NoLog }
})
$listView.Add_SelectedIndexChanged({ Update-ButtonState })
$listView.Add_DoubleClick({ Write-DevcAction 'vscode (double-click)'; Invoke-VsCode })   # §4: double-click = VS Code attach

# filter box: re-render the visible rows as the user types
$txtSearch.Add_TextChanged({ Update-RowFilter })

# right-click selects the row under the cursor so the context menu acts on it
$listView.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $hit = $listView.HitTest($e.Location)
        if ($hit.Item) { $hit.Item.Selected = $true; $listView.Select() }
    }
})
# grey out "Open containing folder" for remote rows (path isn't local)
$rowMenu.Add_Opening({
    param($sender, $e)
    $row = Get-SelectedRow
    if (-not $row) { $e.Cancel = $true; return }
    $win = $null
    if ($row.Path) { $win = ConvertTo-DevcWindowsPath $row.Path }
    $miOpenFolder.Enabled = [bool]$win
    $miCopyPath.Enabled   = [bool]$row.Path
})
$miOpenFolder.Add_Click({ Write-DevcAction 'open folder'; Open-DevcFolder })
$miCopyPath.Add_Click({ Write-DevcAction 'copy path'; Copy-DevcPath })
$miCopyName.Add_Click({ Write-DevcAction 'copy name'; Copy-DevcName })

# column-click sort
$script:SortCol = -1
$script:SortAsc = $true
$listView.Add_ColumnClick({
    param($sender, $e)
    if ($e.Column -eq $script:SortCol) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortCol = $e.Column; $script:SortAsc = $true }
    $listView.ListViewItemSorter = New-Object DevcColumnSorter($e.Column, $script:SortAsc)
    $listView.Sort()
})

# ===========================================================================
# Startup checks + first refresh
# ===========================================================================
$form.Add_Shown({
    # §8.3: warn if CONTAINER_HOST was inherited from the parent shell - it would
    # silently misdirect local podman calls.
    if ($env:CONTAINER_HOST) {
        Set-Status "warning: CONTAINER_HOST inherited ($($env:CONTAINER_HOST)) - local view is skipped to avoid misdirection"
    }
    Invoke-Refresh
})

# ===========================================================================
# Pump timer: reap finished async jobs on the UI thread (§7). Defined last so
# every function it calls already exists; started just before ShowDialog.
# ===========================================================================
$script:Pump = New-Object System.Windows.Forms.Timer
$script:Pump.Interval = 150
$script:PumpBusy = $false
$script:Pump.Add_Tick({
    # An OnDone may open a modal dialog (e.g. the password prompt), whose nested
    # message loop keeps firing this timer. Guard against re-entrant reaping so a
    # job can't be EndInvoke'd twice while a dialog is up.
    if ($script:PumpBusy) { return }
    $script:PumpBusy = $true
    try {
        foreach ($j in @($script:Pending)) {
            if (-not $j.Handle.IsCompleted) { continue }
            [void]$script:Pending.Remove($j)
            try {
                $res = $j.PS.EndInvoke($j.Handle)
                $payload = $null
                if ($res -and $res.Count -gt 0) { $payload = $res[$res.Count - 1] }
                # non-terminating errors inside the worker never reach the UI
                foreach ($e in @($j.PS.Streams.Error)) {
                    Write-DevcLog 'job' "$($j.Label): worker error: $e"
                }
                $outcome = ''
                if ($payload -and $payload.PSObject.Properties['Ok'] -and -not $payload.Ok) {
                    $outcome = " - FAILED: $($payload.Error)"
                }
                Write-DevcLog 'job' ("done {0} in {1} ms{2}" -f $j.Label, $j.Watch.ElapsedMilliseconds, $outcome)
                if ($j.OnDone) { & $j.OnDone $payload }
            } catch {
                Write-DevcLog 'error' "$($j.Label): $($_.Exception.Message)`n$($_.ScriptStackTrace)"
                Set-Status "error: $($_.Exception.Message)"
            } finally {
                $j.PS.Dispose()
            }
        }
    } finally {
        $script:PumpBusy = $false
    }
})
$script:Pump.Start()

# Clean shutdown (§7): stop the pump, kill pending jobs, close the pool. Without
# this the process lingers after the window closes. In finally rather than
# FormClosing so it also runs when the pipeline is stopped (see DevcUiGuard) -
# scriptblock event handlers can't fire then, finally blocks still do.
try {
    [void]$form.ShowDialog()
} finally {
    $script:Pump.Stop()
    foreach ($j in @($script:Pending)) {
        try { if ($j.PS) { $j.PS.Stop(); $j.PS.Dispose() } } catch { }
    }
    $script:Pending.Clear()
    try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
    $form.Dispose()
    Write-DevcLog 'exit' ''
}
