<#
  devc-gui.lib.ps1 - pure data / action layer for devc-gui.ps1.

  NO WinForms in here. This file is dot-sourced by BOTH the GUI process and the
  worker runspaces spawned for async work (a worker runspace cannot see the main
  script's functions or variables, so everything they call must live here). Keep
  it side-effect free apart from the proxy reset below: functions return data or
  perform a single podman/ssh action and report the outcome; they never touch UI.

  Targets Windows PowerShell 5.1. No 7+ syntax (?? ?. ternary, -NoProxy, etc.).
#>

# --- §8.7: a system proxy makes Invoke-RestMethod on 127.0.0.1 slow or flaky.
# Disable proxying for this process (and each worker runspace dot-sourcing us).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy

# §8.4: pin the native Windows OpenSSH build. Plain `ssh` in PATH on this machine
# resolves to the msys/git-bash build, which dies silently when daemonized and
# leaves the dead tunnel of §8.2 behind.
$script:SshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
if (-not (Test-Path $script:SshExe)) { $script:SshExe = 'ssh' }

# libpod REST API prefix used for every remote call.
$script:Api = 'v4.0.0/libpod'

# ---------------------------------------------------------------------------
# Config (%USERPROFILE%\.devc-code.json, written by devc-code.ps1)
# ---------------------------------------------------------------------------

function Get-DevcConfig {
    param([string]$ConfigPath = "$env:USERPROFILE\.devc-code.json")
    if (-not (Test-Path $ConfigPath)) { return $null }
    try { Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $null }
}

# Servers we know about: everything with a cached socket path, plus the last
# saved -Server. Used to populate the "Connect server" picker.
function Get-DevcKnownServers {
    param([string]$ConfigPath = "$env:USERPROFILE\.devc-code.json")
    $cfg = Get-DevcConfig -ConfigPath $ConfigPath
    $servers = New-Object System.Collections.Generic.List[string]
    if ($cfg -and $cfg.Sockets) {
        $cfg.Sockets.PSObject.Properties | ForEach-Object {
            if ($servers -notcontains $_.Name) { $servers.Add($_.Name) }
        }
    }
    if ($cfg -and $cfg.Server -and ($servers -notcontains $cfg.Server)) { $servers.Add($cfg.Server) }
    @($servers)
}

# ---------------------------------------------------------------------------
# Tunnel inventory (§5.1) - reconstructed from live ssh.exe processes, no state
# file. Each of devc-code.ps1's tunnels is `ssh ... -L <port>:<sock> <server>`.
# ---------------------------------------------------------------------------

function Get-DevcTunnels {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -match '-L\s+(\d+):\S*podman\.sock\s+(\S+)\s*$') {
            [pscustomobject]@{ Port = [int]$Matches[1]; Server = $Matches[2]; ProcId = $_.ProcessId }
        }
    }
}

# Quick liveness probe for a tunnel - cheaper than listing containers, and it
# has a real timeout so a dead ssh session (port still listening, §8.2) can't
# hang us forever.
function Test-DevcTunnel {
    param([int]$Port, [int]$TimeoutSec = 5)
    try {
        [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/$script:Api/_ping" -TimeoutSec $TimeoutSec)
        $true
    } catch { $false }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Container name -> project folder name. Name is devc-<folder>-<md5hash8>; the
# folder is everything between the devc- prefix and the trailing 8 hex chars.
# The FULL project path is NOT recoverable from the name (it's a hash) - read it
# from the /workspace mount instead (Get-DevcContainerPath).
function Get-DevcProjectName {
    param([string]$Name)
    if ($Name -match '^devc-(.+)-[0-9a-f]{8}$') { $Matches[1] } else { $Name }
}

# host part of a user@host / host / alias ssh target, for the Location column.
function Get-DevcLocationLabel {
    param([string]$Server)
    ($Server -replace '^.*@', '')
}

function ConvertTo-DevcHttp {
    param([string]$Url)  # tcp://127.0.0.1:8889 -> http://127.0.0.1:8889
    $Url -replace '^tcp://', 'http://'
}

# Translate a container's /workspace mount source into a Windows path openable in
# Explorer, or $null when it isn't local. The local podman machine runs in WSL,
# so a local project bind-mounted from C:\foo is recorded as /mnt/c/foo - map
# /mnt/<drive>/rest -> <DRIVE>:\rest. A path that's already Windows is normalised;
# a genuine remote Linux path (server rows) returns $null.
function ConvertTo-DevcWindowsPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($Path -match '^/mnt/([a-zA-Z])/(.*)$') {
        return ('{0}:\{1}' -f $Matches[1].ToUpper(), ($Matches[2] -replace '/', '\'))
    }
    if ($Path -match '^[a-zA-Z]:[\\/]') { return ($Path -replace '/', '\') }
    return $null
}

# ---------------------------------------------------------------------------
# Reading state - remote (over a tunnel, via REST with a timeout)
# ---------------------------------------------------------------------------

# All devc-* containers on one tunnel. all=true so stopped ones show too.
# Throws on an unresponsive tunnel (timeout) - callers wrap this in a snapshot.
function Get-DevcContainersRemote {
    param([string]$Server, [int]$Port, [int]$TimeoutSec = 5, [switch]$IncludePath)
    $base = "http://127.0.0.1:$Port"
    # §8.1: do NOT wrap the call in @(). PS 5.1 hands back the JSON array as ONE
    # object; @() would nest it so the pipeline sees a single element and every
    # container but the first silently vanishes. Filter with the pipeline, and
    # only put @() on the final Where-Object result.
    $r = Invoke-RestMethod -Uri "$base/$script:Api/containers/json?all=true" -TimeoutSec $TimeoutSec
    $rows = @($r | Where-Object { $_ -and $_.Names -and ($_.Names[0] -like 'devc-*') } | ForEach-Object {
        $name = $_.Names[0]
        [pscustomobject]@{
            Server   = $Server
            Location = (Get-DevcLocationLabel $Server)
            IsLocal  = $false
            Url      = "tcp://127.0.0.1:$Port"
            Port     = $Port
            Name     = $name
            Project  = (Get-DevcProjectName $name)
            State    = "$($_.State)"
            Image    = "$($_.Image)"
            Path     = $null
        }
    })
    if ($IncludePath) {
        foreach ($row in $rows) {
            try { $row.Path = Get-DevcContainerPath -Row $row -TimeoutSec $TimeoutSec } catch { }
        }
    }
    $rows
}

# One server's full result, never throwing: { Server; Port; Ok; Rows; Error }.
# This is what a per-server refresh worker returns so one dead tunnel neither
# throws nor stalls the others (§7).
function Get-DevcServerSnapshot {
    param([string]$Server, [int]$Port, [int]$TimeoutSec = 5)
    try {
        $rows = Get-DevcContainersRemote -Server $Server -Port $Port -TimeoutSec $TimeoutSec -IncludePath
        [pscustomobject]@{ Server = $Server; Port = $Port; Ok = $true; Rows = @($rows); Error = $null }
    } catch {
        [pscustomobject]@{ Server = $Server; Port = $Port; Ok = $false; Rows = @(); Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Reading state - local (podman CLI; local podman speaks a named pipe, not TCP,
# so Invoke-RestMethod can't reach it in PS 5.1 - §5.2)
# ---------------------------------------------------------------------------

# Returns { Ok; Rows; Error }. Never throws; the three failure modes of §5.2
# each get their own message so the GUI can show it without an exception.
function Get-DevcContainersLocal {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Error = 'podman not installed' }
    }
    # §8.3: an inherited CONTAINER_HOST silently redirects every local podman
    # call to a remote server (surfacing as a baffling "statfs ...: no such file
    # or directory"). Refuse to run local reads through it rather than lie.
    if ($env:CONTAINER_HOST) {
        return [pscustomobject]@{
            Ok = $false; Rows = @()
            Error = "CONTAINER_HOST is set ($($env:CONTAINER_HOST)) - local view skipped so it isn't misdirected"
        }
    }

    $names = & podman ps -a --filter 'name=^devc-' --format '{{.Names}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = ("$names").Trim()
        if ($msg -match 'machine|not running|unable to connect|Cannot connect') {
            return [pscustomobject]@{ Ok = $false; Rows = @(); Error = "podman machine not running (podman machine start): $msg" }
        }
        return [pscustomobject]@{ Ok = $false; Rows = @(); Error = "podman ps failed: $msg" }
    }
    $names = @($names | Where-Object { $_ -and "$_".Trim() } | ForEach-Object { "$_".Trim() })
    if ($names.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Rows = @(); Error = $null } }

    # One inspect for all of them - path (/workspace mount source), state, image.
    $rows = @()
    try {
        $objs = & podman inspect @names 2>$null | Out-String | ConvertFrom-Json
        foreach ($o in @($objs)) {
            $name = ($o.Name -replace '^/', '')
            $path = ($o.Mounts | Where-Object { $_.Destination -eq '/workspace' } | Select-Object -First 1).Source
            $rows += [pscustomobject]@{
                Server   = 'local'
                Location = 'local'
                IsLocal  = $true
                Url      = $null
                Port     = 0
                Name     = $name
                Project  = (Get-DevcProjectName $name)
                State    = "$($o.State.Status)"
                Image    = "$($o.ImageName)"
                Path     = $path
            }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Rows = @(); Error = "podman inspect failed: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Ok = $true; Rows = @($rows); Error = $null }
}

# ---------------------------------------------------------------------------
# Project path from the /workspace mount (§5). Works for both sides.
# ---------------------------------------------------------------------------

function Get-DevcContainerPath {
    param([pscustomobject]$Row, [int]$TimeoutSec = 5)
    if ($Row.IsLocal) {
        $out = & podman inspect --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' $Row.Name 2>$null
        return ("$out").Trim()
    }
    $base = ConvertTo-DevcHttp $Row.Url
    $i = Invoke-RestMethod -Uri "$base/$script:Api/containers/$($Row.Name)/json" -TimeoutSec $TimeoutSec
    ($i.Mounts | Where-Object { $_.Destination -eq '/workspace' } | Select-Object -First 1).Source
}

# ---------------------------------------------------------------------------
# Actions - start / stop / restart / remove (§3). REST for remote, CLI for local.
# All throw on failure; callers run them async and report via OnDone.
# ---------------------------------------------------------------------------

function Invoke-DevcLifecycle {
    param(
        [pscustomobject]$Row,
        [ValidateSet('start', 'stop', 'restart')][string]$Action,
        [int]$TimeoutSec = 30
    )
    if ($Row.IsLocal) {
        $out = & podman $Action $Row.Name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "podman $Action $($Row.Name): $(("$out").Trim())" }
        return
    }
    $base = ConvertTo-DevcHttp $Row.Url
    [void](Invoke-RestMethod -Method Post -Uri "$base/$script:Api/containers/$($Row.Name)/$Action" -TimeoutSec $TimeoutSec)
}

function Remove-DevcContainer {
    param([pscustomobject]$Row, [int]$TimeoutSec = 30)
    if ($Row.IsLocal) {
        $out = & podman rm -f $Row.Name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "podman rm $($Row.Name): $(("$out").Trim())" }
        return
    }
    $base = ConvertTo-DevcHttp $Row.Url
    [void](Invoke-RestMethod -Method Delete -Uri "$base/$script:Api/containers/$($Row.Name)?force=true" -TimeoutSec $TimeoutSec)
}

# ---------------------------------------------------------------------------
# Logs (§3) - last N lines as text.
# ---------------------------------------------------------------------------

function Get-DevcLogs {
    param([pscustomobject]$Row, [int]$Tail = 200, [int]$TimeoutSec = 15)
    if ($Row.IsLocal) {
        $out = & podman logs --tail $Tail $Row.Name 2>&1
        return (($out | Out-String))
    }
    $base = ConvertTo-DevcHttp $Row.Url
    $uri = "$base/$script:Api/containers/$($Row.Name)/logs?stdout=true&stderr=true&tail=$Tail"
    $resp = Invoke-WebRequest -Uri $uri -TimeoutSec $TimeoutSec -UseBasicParsing
    $text = "$($resp.Content)"
    # devc containers are created with -it (a TTY), so the log stream is raw and
    # needs no de-multiplexing. Strip stray control bytes best-effort in case a
    # container was created without a TTY (then the 8-byte frame headers leak in).
    # tab/CR/LF kept; printable ASCII and all Unicode above 0x7F pass through.
    $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
}

# ---------------------------------------------------------------------------
# Tunnel creation for "Connect server" (§8.5/§8.6). devc-code.ps1 couples the
# tunnel to a VS Code attach (and its picker Read-Host would hang a hidden GUISy
# process), so for a pure key-auth connect we open the tunnel the same way it
# does. The password case is handled by the GUI launching devc-code.ps1 visibly.
# ---------------------------------------------------------------------------

# Does key/agent auth work without a prompt? (§8.6 step 1). Runs through the
# bounded, killable runner: BatchMode + ConnectTimeout stop ssh blocking on a
# prompt or a dead host, and the wall-clock timeout guarantees we get control
# back even if ssh wedges for any other reason (this froze a real connect).
# Returns { Ok; Reason; TimedOut } - Reason carries ssh's own stderr so a key
# server wrongly falling to the password path can be diagnosed (Permission
# denied / timed out / agent unreachable).
# Only pin -i when the key file actually exists; otherwise let ssh use the agent
# and ~/.ssh/config exactly like a plain `ssh <server>` would.
function Test-DevcKeyAuth {
    param([string]$Server, [string]$Identity, [int]$ConnectTimeout = 10)
    $idArgs = @()
    if ($Identity -and (Test-Path $Identity)) { $idArgs = @('-i', $Identity) }
    # ControlPath=none: never reuse or create a shared ssh master. A stale
    # ControlMaster socket (from ~/.ssh/config multiplexing) makes a fresh ssh
    # block after the TCP connect - which looks exactly like this timeout.
    $r = Start-DevcSshScoped -Wait -CaptureError -TimeoutSec ($ConnectTimeout + 5) -SshArgs (
        $idArgs + @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes',
                    '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                    '-o', "ConnectTimeout=$ConnectTimeout", $Server, 'exit'))
    $ok = ($r -and -not $r.TimedOut -and $r.ExitCode -eq 0)
    $reason = 'no result'
    if ($r -and $r.TimedOut) { $reason = "timed out after $($ConnectTimeout + 5)s" }
    elseif ($r) { $reason = "$($r.Err)".Trim(); if (-not $reason) { $reason = "ssh exit $($r.ExitCode)" } }
    [pscustomobject]@{ Ok = $ok; Reason = $reason; TimedOut = ($r -and $r.TimedOut) }
}

# Open (or reuse) a hidden key-auth tunnel; returns { Port; Reused; Server }.
# Throws if key auth isn't available - the caller falls back to the visible
# devc-code.ps1 path for password servers.
function Connect-DevcTunnel {
    param(
        [string]$Server,
        [string]$Identity,
        [int]$BasePort = 8889,
        [string]$ConfigPath = "$env:USERPROFILE\.devc-code.json"
    )
    if (-not $Identity) {
        $cfg = Get-DevcConfig -ConfigPath $ConfigPath
        if ($cfg -and $cfg.Identity) { $Identity = $cfg.Identity } else { $Identity = "$env:USERPROFILE\.ssh\id_ed25519" }
    }

    # reuse a live tunnel; rebuild a dead one (port listens but forwards nowhere).
    $existing = Get-DevcTunnels | Where-Object { $_.Server -eq $Server } | Select-Object -First 1
    if ($existing) {
        if (Test-DevcTunnel -Port $existing.Port) {
            return [pscustomobject]@{ Port = $existing.Port; Reused = $true; Server = $Server }
        }
        Stop-Process -Id $existing.ProcId -Force -ErrorAction SilentlyContinue
    }

    $auth = Test-DevcKeyAuth -Server $Server -Identity $Identity
    if (-not $auth.Ok) {
        # keep the "key auth not available" prefix (the GUI matches on it to offer
        # the password path) and append ssh's real reason for diagnosis.
        throw "key auth not available for $Server :: $($auth.Reason)"
    }

    # rootless podman socket path (depends only on the remote uid). Reuse the
    # cached one so we don't need a second ssh round-trip.
    $socket = $null
    $cfg = Get-DevcConfig -ConfigPath $ConfigPath
    if ($cfg -and $cfg.Sockets -and $cfg.Sockets.$Server) { $socket = $cfg.Sockets.$Server }
    if (-not $socket) {
        # bounded/killable discovery so a stalled ssh can't hang the connect.
        $disc = Start-DevcSshScoped -Wait -TimeoutSec 15 -SshArgs @(
            '-i', $Identity, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes',
            '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
            '-o', 'ConnectTimeout=10', $Server, 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"')
        if (-not $disc -or $disc.TimedOut -or $disc.ExitCode -ne 0) {
            throw "cannot ssh to $Server for socket discovery (key auth / network)"
        }
        $socket = "$($disc.Out)".Trim()
        if (-not $socket) { throw "cannot discover podman socket path on $Server" }
    }

    $port = Get-DevcFreePort -Start $BasePort
    # §8.5: Win32-OpenSSH has no -f; a plain -N tunnel launched hidden & detached
    # survives this process. Wait until the port is actually listening.
    $tunArgs = @('-i', $Identity, '-o', 'StrictHostKeyChecking=accept-new', '-N',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-o', 'ConnectTimeout=10', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30',
        '-L', "${port}:${socket}", $Server)
    $proc = Start-Process -FilePath $script:SshExe -ArgumentList $tunArgs -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { break }
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
        throw "tunnel to $Server did not come up on port $port"
    }
    [pscustomobject]@{ Port = $port; Reused = $false; Server = $Server }
}

function Get-DevcFreePort {
    param([int]$Start = 8889)
    $used = @((Get-DevcTunnels).Port)
    for ($p = $Start; $p -lt $Start + 200; $p++) {
        if ($used -contains $p) { continue }
        if (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) { continue }
        return $p
    }
    throw "no free local port near $Start"
}

function Disconnect-DevcTunnel {
    param([string]$Server)
    $tns = @(Get-DevcTunnels | Where-Object { $_.Server -eq $Server })
    foreach ($t in $tns) { Stop-Process -Id $t.ProcId -Force -ErrorAction SilentlyContinue }
    return $tns.Count
}

# ---------------------------------------------------------------------------
# Password servers without a console (askpass). Native OpenSSH reads the
# password from a real console, which a hidden GUI doesn't have (§8.6). Its
# supported no-console path is SSH_ASKPASS: when ssh has no tty it runs that
# program and reads the password from its stdout. We collect the password in a
# GUI dialog, hand it to a tiny generated helper via a child-only env var
# (never on disk, never in this process's env), and bring the tunnel up hidden
# and detached - exactly like a key-auth tunnel. The GUI falls back to the
# visible devc-code.ps1 console if any of this fails (old OpenSSH, wrong pass).
# ---------------------------------------------------------------------------

# Compile a one-shot console exe that echoes $env:DEVC_SSH_PW. Built once per
# machine into LOCALAPPDATA (persists; the exe holds no secret - it reads the
# password from its environment at run time). Returns the path.
function New-DevcAskPassExe {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $env:LOCALAPPDATA 'devc-gui\devc-askpass.exe' }
    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path $Path) { return $Path }
    $code = @'
public class DevcAskPass {
    public static void Main() {
        string pw = System.Environment.GetEnvironmentVariable("DEVC_SSH_PW");
        if (pw == null) pw = "";
        // ssh reads the first line of stdout and strips the newline.
        System.Console.Out.Write(pw + "\n");
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -OutputType ConsoleApplication -OutputAssembly $Path
    return $Path
}

# Run ssh with an env scoped to the child only (§8.3), no console window.
# -Wait captures stdout (for socket discovery); otherwise returns the detached
# Process (for the long-lived tunnel). stderr is left un-redirected so a chatty
# banner can't deadlock the stdout read.
function Start-DevcSshScoped {
    param([string[]]$SshArgs, [hashtable]$ChildEnv, [switch]$Wait, [switch]$CaptureError, [int]$TimeoutSec = 30)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:SshExe
    $hasList = $psi.PSObject.Properties.Name -contains 'ArgumentList'
    if ($hasList) {
        foreach ($a in $SshArgs) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = ($SshArgs | ForEach-Object {
            if ("$_" -match '\s|"') { '"{0}"' -f ("$_" -replace '"', '\"') } else { "$_" }
        }) -join ' '
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($Wait) { $psi.RedirectStandardOutput = $true }
    if ($Wait -and $CaptureError) { $psi.RedirectStandardError = $true }
    if ($ChildEnv) { foreach ($k in $ChildEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ChildEnv[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $Wait) { return $p }
    # Read the pipes asynchronously and bound the wait with WaitForExit: reading
    # synchronously with ReadToEnd() would block until the child closes the pipe,
    # so a hung ssh (no exit, no close) would ignore the timeout entirely. Kick
    # off the reads, then enforce the deadline and Kill if it's blown.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $null
    if ($CaptureError) { $errTask = $p.StandardError.ReadToEndAsync() }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = $null; Out = ''; Err = ''; TimedOut = $true }
    }
    $out = ''; $err = ''
    try { $out = $outTask.GetAwaiter().GetResult() } catch { }
    if ($errTask) { try { $err = $errTask.GetAwaiter().GetResult() } catch { } }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err; TimedOut = $false }
}

# Open (or reuse) a hidden tunnel to a password server, feeding the password via
# SSH_ASKPASS. Throws on failure so the GUI can fall back to the console path.
function Connect-DevcTunnelPassword {
    param(
        [string]$Server,
        [string]$Password,
        [string]$AskPassExe,
        [string]$Identity,
        [int]$BasePort = 8889,
        [string]$ConfigPath = "$env:USERPROFILE\.devc-code.json"
    )
    if (-not $Identity) {
        $cfg = Get-DevcConfig -ConfigPath $ConfigPath
        if ($cfg -and $cfg.Identity) { $Identity = $cfg.Identity } else { $Identity = "$env:USERPROFILE\.ssh\id_ed25519" }
    }

    $existing = Get-DevcTunnels | Where-Object { $_.Server -eq $Server } | Select-Object -First 1
    if ($existing) {
        if (Test-DevcTunnel -Port $existing.Port) {
            return [pscustomobject]@{ Port = $existing.Port; Reused = $true; Server = $Server }
        }
        Stop-Process -Id $existing.ProcId -Force -ErrorAction SilentlyContinue
    }

    # child-only env: DISPLAY + SSH_ASKPASS_REQUIRE=force cover both new and older
    # OpenSSH builds; DEVC_SSH_PW carries the secret to the helper, nowhere else.
    $childEnv = @{
        SSH_ASKPASS         = $AskPassExe
        SSH_ASKPASS_REQUIRE = 'force'
        DISPLAY             = 'localhost:0'
        DEVC_SSH_PW         = $Password
    }
    $common = @('-i', $Identity, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'NumberOfPasswordPrompts=1')

    # rootless podman socket path - cached per server so repeat connects need no
    # discovery ssh (one fewer password round-trip).
    $socket = $null
    $cfg = Get-DevcConfig -ConfigPath $ConfigPath
    if ($cfg -and $cfg.Sockets -and $cfg.Sockets.$Server) { $socket = $cfg.Sockets.$Server }
    if (-not $socket) {
        $disc = Start-DevcSshScoped -Wait -TimeoutSec 30 -ChildEnv $childEnv -SshArgs (
            $common + @($Server, 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"'))
        if (-not $disc -or $disc.TimedOut -or $disc.ExitCode -ne 0) {
            throw "password auth/discovery failed for $Server (wrong password, or this OpenSSH build ignores SSH_ASKPASS)"
        }
        $socket = ("$($disc.Out)").Trim()
        if (-not $socket) { throw "could not discover podman socket path on $Server" }
        Save-DevcSocket -Server $Server -Socket $socket -ConfigPath $ConfigPath
    }

    $port = Get-DevcFreePort -Start $BasePort
    $proc = Start-DevcSshScoped -ChildEnv $childEnv -SshArgs (
        $common + @('-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30',
                    '-L', "${port}:${socket}", $Server))
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { break }
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        throw "password tunnel to $Server did not come up (auth failed, or SSH_ASKPASS unsupported)"
    }
    [pscustomobject]@{ Port = $port; Reused = $false; Server = $Server }
}

# Persist a discovered socket path into ~/.devc-code.json, preserving the shape
# devc-code.ps1 uses (Server / Identity / Sockets) so both tools stay compatible.
function Save-DevcSocket {
    param([string]$Server, [string]$Socket, [string]$ConfigPath = "$env:USERPROFILE\.devc-code.json")
    $cfg = Get-DevcConfig -ConfigPath $ConfigPath
    $sockets = @{}
    if ($cfg -and $cfg.Sockets) { $cfg.Sockets.PSObject.Properties | ForEach-Object { $sockets[$_.Name] = $_.Value } }
    $sockets[$Server] = $Socket
    $identity = $null; $savedServer = $null
    if ($cfg) { $identity = $cfg.Identity; $savedServer = $cfg.Server }
    [pscustomobject]@{ Server = $savedServer; Identity = $identity; Sockets = $sockets } |
        ConvertTo-Json | Set-Content $ConfigPath
}
