<#
.SYNOPSIS
  Open a VS Code window attached to a devc podman container running on a remote
  Linux server, from Windows - without touching your local podman setup.
  Multiple servers can be connected at once.

.DESCRIPTION
  podman's own ssh client on Windows is broken (drops the host -> "dial tcp :22
  ... refused"), so this script tunnels the remote rootless podman socket to a
  local TCP port over OpenSSH (which works fine).

  To reach the container, VS Code's Dev Containers extension must run `podman`
  against that tunnel. We do NOT change the local podman default connection
  (that would break your local podman). Instead we set CONTAINER_HOST /
  DOCKER_HOST only for the process we launch, and start an isolated VS Code
  instance (its own --user-data-dir, shared extensions) that inherits them and
  won't hand off to your main VS Code. Local podman and main VS Code stay
  untouched.

  Multi-server: each -Server gets its own tunnel on an automatically chosen
  free local port, so several servers stay connected simultaneously without
  colliding. The container picker then lists devc-* containers from EVERY
  connected server. Each server also gets its own VS Code profile
  (~\.devc-vscode\<server>) so the windows don't reuse one instance's stale
  CONTAINER_HOST.

  Nothing is hard-coded: -Identity defaults from a config file
  (default ~\.devc-code.json), saved on first run. The remote uid (socket path)
  is discovered over ssh.

.PARAMETER Server
  ssh target (user@host, host, or ssh config alias) to connect / reconnect.
  Omit to just pick from servers already connected.

.PARAMETER LocalPort
  Force a specific local port for a NEW tunnel. 0 (default) = pick a free one.

.PARAMETER NoClean
  Skip clearing the container's VS Code server. Use when re-focusing a
  container you already have a window attached to (the clean step would drop it).

.EXAMPLE
  .\devc-code.ps1 -Server user@host        # open/reuse a tunnel, then pick a container
  .\devc-code.ps1                          # pick from all currently connected servers
  .\devc-code.ps1 -Container devc-myproj-1a2b3c4d
  .\devc-code.ps1 -Stop                    # stop ALL devc tunnels
  .\devc-code.ps1 -Server user@host -Stop  # stop just that server's tunnel
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Identity,
    [int]   $LocalPort  = 0,
    [string]$Container,
    [string]$Workspace  = "/workspace",
    [string]$ProfileDir,
    [string]$ExtDir     = "$env:USERPROFILE\.vscode\extensions",
    [string]$ConfigPath = "$env:USERPROFILE\.devc-code.json",
    [int]   $BasePort   = 8889,
    [switch]$NoClean,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

# --- config: only -Identity has a persisted default (server is per-run now) ----
$cfg = $null
if (Test-Path $ConfigPath) { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
if (-not $Identity -and $cfg -and $cfg.Identity) { $Identity = $cfg.Identity }
if (-not $Identity) { $Identity = "$env:USERPROFILE\.ssh\id_ed25519" }
$sshArgs = @("-i", $Identity)

# Plain `ssh` can resolve to the msys/git-bash build (first in PATH), which
# tends to die silently when daemonized with -f on Windows: the process and
# the local port live on, but the session is gone, so every podman call
# through the tunnel hangs. Pin the native Windows OpenSSH build when present.
$sshExe = Join-Path $env:SystemRoot "System32\OpenSSH\ssh.exe"
if (-not (Test-Path $sshExe)) { $sshExe = "ssh" }

# accept-new: auto-trust an unknown host key instead of the interactive yes/no
# prompt (which broke the run under non-interactive parsing).
$hkOpts = @("-o", "StrictHostKeyChecking=accept-new")

# Per-server podman socket path, cached in the config. The path only depends on
# the remote uid, so once discovered it never changes - caching it lets repeat
# runs skip the discovery ssh, so a password server is asked for the password
# just once (at the tunnel) instead of twice.
$script:Sockets = @{}
if ($cfg -and $cfg.Sockets) {
    $cfg.Sockets.PSObject.Properties | ForEach-Object { $script:Sockets[$_.Name] = $_.Value }
}
$script:CfgDirty = $false

function Save-Config {
    [pscustomobject]@{ Server = $Server; Identity = $Identity; Sockets = $script:Sockets } |
        ConvertTo-Json | Set-Content $ConfigPath
}

# --- tunnel inventory: one ssh.exe per connected server ------------------------
# Each of our tunnels is `ssh ... -L <port>:<remote podman.sock> <server>`, so we
# can recover both the local port and the server it points at from the cmdline.
function Get-Tunnels {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | ForEach-Object {
        if ($_.CommandLine -match '-L\s+(\d+):\S*podman\.sock\s+(\S+)\s*$') {
            [pscustomobject]@{ Port = [int]$Matches[1]; Server = $Matches[2]; ProcId = $_.ProcessId }
        }
    }
}

function Get-FreePort {
    param([int]$Start)
    $used = @((Get-Tunnels).Port)
    for ($p = $Start; $p -lt $Start + 200; $p++) {
        if ($used -contains $p) { continue }
        if (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) { continue }
        return $p
    }
    throw "no free local port near $Start"
}

# List one tunnel's devc-* containers, but never block forever on it. When a
# tunnel's ssh session has silently died the local port keeps listening, so
# `podman ... ps` connects and then hangs indefinitely (podman has no timeout) -
# which would freeze the whole script on that one dead server. Instead of the
# podman CLI, hit podman's REST API directly: Invoke-RestMethod has a real
# timeout and skips both podman.exe startup and Start-Job overhead (~1 s each
# in PS 5.1), which added many seconds to every run. Returns the name array,
# or $null if the tunnel was unresponsive.
function Get-DevcNames {
    param([string]$Url, [int]$TimeoutSec = 5)
    $base = $Url -replace '^tcp://', 'http://'
    try {
        # filter names locally; NOTE: do not wrap the call in @() - PS 5.1
        # returns the JSON array as ONE object, and @() would nest it so the
        # pipeline sees a single item and only the first container survives.
        $r = Invoke-RestMethod -Uri "$base/v4.0.0/libpod/containers/json" -TimeoutSec $TimeoutSec
        return @($r | Where-Object { $_ } | ForEach-Object { $_.Names[0] } | Where-Object { $_ -like 'devc-*' })
    } catch {
        return $null
    }
}

if ($Stop) {
    $tns = @(Get-Tunnels)
    if ($Server) { $tns = @($tns | Where-Object { $_.Server -eq $Server }) }
    if ($tns.Count -eq 0) { Write-Host "no devc tunnels running$(if ($Server) { " for $Server" })"; return }
    foreach ($t in $tns) {
        Stop-Process -Id $t.ProcId -Force
        Write-Host "stopped tunnel $($t.Port) -> $($t.Server)"
    }
    return
}

# --- ensure (or reuse) a tunnel for a given server; returns its local port -----
function Connect-Server {
    param([string]$Srv, [int]$ForcePort)
    # ssh writes harmless notices (host-key add, banners) to stderr; under a Stop
    # preference PowerShell turns those into terminating errors, so relax it here.
    $ErrorActionPreference = 'Continue'

    $existing = Get-Tunnels | Where-Object { $_.Server -eq $Srv } | Select-Object -First 1
    if ($existing) {
        # A silently dead ssh session keeps its port listening, so probe before
        # reusing - otherwise everything downstream hangs on a tunnel that
        # forwards nowhere (and the dead-tunnel sweep in step 2 would only tear
        # it down, skipping this server until the NEXT run).
        if ($null -ne (Get-DevcNames -Url "tcp://127.0.0.1:$($existing.Port)")) {
            Write-Host "tunnel to $Srv already up on $($existing.Port)"
            return $existing.Port
        }
        Write-Warning "tunnel $($existing.Port) -> $Srv is unresponsive; rebuilding it"
        Stop-Process -Id $existing.ProcId -Force -ErrorAction SilentlyContinue
    }
    # rootless podman socket path (depends only on the remote uid). Cached per
    # server, so only the FIRST ever connect to a server runs this discovery ssh.
    $socket = $script:Sockets[$Srv]
    if (-not $socket) {
        $socket = (& $sshExe @sshArgs @hkOpts $Srv 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"')
        if (-not $socket) { throw "cannot ssh to $Srv ($Identity / password) - check 'ssh $Srv'." }
        $socket = "$socket".Trim()
        $script:Sockets[$Srv] = $socket
        $script:CfgDirty = $true
    }

    $port = if ($ForcePort -gt 0) { $ForcePort } else { Get-FreePort -Start $BasePort }
    Write-Host "opening tunnel $port -> ${Srv}:$socket"

    # Win32-OpenSSH does not implement -f: it authenticates but never forks to
    # the background, so msys-style `-f -N` daemonization would block the
    # script on the ssh line forever. Launch a plain -N tunnel via
    # Start-Process instead: with key/agent auth as a hidden detached process
    # (survives this console); when the server wants a password, in THIS
    # console (-NoNewWindow) so the prompt is typed right here - the tunnel
    # then lives only as long as this console does.
    $tunArgs = $sshArgs + $hkOpts +
        @('-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30', '-L', "${port}:${socket}", $Srv) |
        ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } }

    & $sshExe @sshArgs @hkOpts -o BatchMode=yes -o ConnectTimeout=10 $Srv exit 2>$null
    if ($LASTEXITCODE -eq 0) {
        $waitSec = 20
        $proc = Start-Process -FilePath $sshExe -ArgumentList $tunArgs -WindowStyle Hidden -PassThru
    } else {
        $waitSec = 180
        Write-Host "key auth not available for $Srv - enter the password below. The tunnel stays tied to THIS console (closing it drops the tunnel); install your key on the server to avoid both."
        $proc = Start-Process -FilePath $sshExe -ArgumentList $tunArgs -NoNewWindow -PassThru
    }
    for ($i = 0; $i -lt $waitSec * 4; $i++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { break }
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
        throw "tunnel did not come up on $port - check that 'ssh $Srv' works."
    }
    return $port
}

# nothing up yet and no -Server: fall back to the saved server for a quick start
if (-not $Server -and (Get-Tunnels | Measure-Object).Count -eq 0 -and $cfg -and $cfg.Server) {
    $Server = $cfg.Server
    Write-Host "no tunnels up; connecting to saved server $Server"
}

# --- 1) bring up / reuse the tunnel for -Server (port chosen automatically) ----
if ($Server) {
    [void](Connect-Server -Srv $Server -ForcePort $LocalPort)
    if (-not (Test-Path $ConfigPath) -or $script:CfgDirty) {
        Save-Config
        Write-Host "saved defaults to $ConfigPath"
    }
}

# --- 2) gather devc-* containers from EVERY connected server -------------------
$tunnels = @(Get-Tunnels)
if ($tunnels.Count -eq 0) {
    Write-Error "no connected servers. Run with -Server user@host to open one."
    return
}

$all = foreach ($t in $tunnels) {
    $u  = "tcp://127.0.0.1:$($t.Port)"
    $cs = Get-DevcNames -Url $u
    if ($null -eq $cs) {
        # Port listens but forwards nowhere (dead ssh session). Tear it down so a
        # later `-Server $($t.Server)` run rebuilds it cleanly, then skip it
        # instead of hanging the whole picker on this one server.
        Write-Warning "tunnel $($t.Port) -> $($t.Server) is unresponsive; tearing it down. Reconnect with: .\devc-code.ps1 -Server $($t.Server)"
        Stop-Process -Id $t.ProcId -Force -ErrorAction SilentlyContinue
        continue
    }
    foreach ($c in $cs) {
        [pscustomobject]@{ Server = $t.Server; Port = $t.Port; Url = $u; Name = $c }
    }
}
$all = @($all)
if ($all.Count -eq 0) {
    Write-Error "no running devc-* containers on any connected server ($($tunnels.Server -join ', '))."
    return
}

# --- 3) pick the container (across all servers) --------------------------------
$pick = $null
if ($Container) {
    $cand = @($all | Where-Object { $_.Name -eq $Container })
    if ($Server) { $cand = @($cand | Where-Object { $_.Server -eq $Server }) }
    if     ($cand.Count -eq 0) { Write-Error "container '$Container' not visible on any connected server."; return }
    elseif ($cand.Count -gt 1) { Write-Error "container '$Container' exists on multiple servers ($(($cand.Server) -join ', ')) - add -Server to disambiguate."; return }
    $pick = $cand[0]
}
elseif ($all.Count -eq 1) {
    $pick = $all[0]
}
else {
    Write-Host "containers on connected servers:"
    for ($i = 0; $i -lt $all.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2})" -f $i, $all[$i].Name, $all[$i].Server)
    }
    $sel  = Read-Host "select #"
    $pick = $all[[int]$sel]
}

$Container = $pick.Name
$url       = $pick.Url
Write-Host "ok: '$Container' on $($pick.Server) reachable via $url"

# per-server VS Code profile (unless explicitly overridden) so each server runs
# as its own instance with its own CONTAINER_HOST - a shared profile would make
# `code` hand the new window to an already-running instance with the wrong host.
if (-not $PSBoundParameters.ContainsKey('ProfileDir')) {
    $key        = ($pick.Server -replace '[^A-Za-z0-9]', '_')
    $ProfileDir = "$env:USERPROFILE\.devc-vscode\$key"
}

# --- 4) clear any hung VS Code server in the container (fixes "never connects") -
# A stale/orphaned vscode-server `node` process (e.g. left by a dropped session)
# makes a fresh attach hang forever. Restarting the whole container clears it, but
# that also kills everything else running inside. Instead, kill just the server
# processes and remove the server deployment so VS Code respawns one cleanly on
# attach; your running work in the container survives. No-op on a healthy first
# connect.
#
# We must remove `bin/` (and the IPC sockets), not just the *.lock files: after we
# kill the old server's node process, VS Code's incoming connection still finds the
# old agent's recorded pid/pgid, tries to reap it with `kill -9 -<pgid>`, and since
# the process is already gone the pgid resolves to 0 -> `kill -9 -0` SIGKILLs the
# attach's own process group (bootstrap shell dies with code 137). Nuking bin/
# leaves no phantom agent record to mis-reap. `extensions/` is kept, so remote
# extensions are not re-installed; only the server binary re-downloads.
#
# NOTE: if you have a working window already attached to this container, this will
# drop that session - pass -NoClean to just re-focus it instead.
if (-not $NoClean) {
    $cleanup = @'
pkill -TERM -f '/.vscode-server/' 2>/dev/null || true
sleep 1
pkill -KILL -f '/.vscode-server/' 2>/dev/null || true
rm -rf "$HOME/.vscode-server/bin" 2>/dev/null || true
rm -f /tmp/vscode-ipc-*.sock "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/vscode-ipc-*.sock 2>/dev/null || true
exit 0
'@
    Write-Host "clearing any stale VS Code server in '$Container'"
    # Same job-with-timeout guard as Get-DevcNames: if the tunnel dies between
    # the container listing and this exec, podman would hang here forever.
    $job = Start-Job { param($u, $c, $s) & podman --url $u exec $c /bin/sh -c $s 2>$null } -ArgumentList $url, $Container, $cleanup
    if (-not (Wait-Job $job -Timeout 30)) {
        Write-Warning "cleanup in '$Container' timed out; attaching anyway"
    }
    Remove-Job $job -Force
}

# --- 5) isolated VS Code profile: seed once from your main profile + dockerPath -
$profUser = Join-Path $ProfileDir "User"
New-Item -ItemType Directory -Force -Path $profUser | Out-Null
$settings = Join-Path $profUser "settings.json"
$mainUser = Join-Path $env:APPDATA "Code\User"
if (-not (Test-Path $settings)) {
    $mainSettings = Join-Path $mainUser "settings.json"
    if (Test-Path $mainSettings) { Copy-Item $mainSettings $settings } else { Set-Content $settings "{}" -NoNewline }
    $mainKeys = Join-Path $mainUser "keybindings.json"
    if (Test-Path $mainKeys) { Copy-Item $mainKeys (Join-Path $profUser "keybindings.json") }
}
$txt = Get-Content $settings -Raw
if ($txt -notmatch 'dev\.containers\.dockerPath') {
    if ($txt.Trim() -in @("", "{}")) {
        $txt = "{`n    `"dev.containers.dockerPath`": `"podman`"`n}"
    } else {
        $txt = ([regex]'\{').Replace($txt, "{`n    `"dev.containers.dockerPath`": `"podman`",", 1)
    }
    Set-Content $settings $txt -NoNewline
}

# --- 6) point podman at the tunnel for the VS Code child process only ---------
# A .ps1 runs in the caller's process, so a plain $env: assignment would leak
# into the interactive shell and silently redirect later local podman/devc
# calls to this server. Set it just around the launch and restore afterwards.
$hex = (([System.Text.Encoding]::ASCII.GetBytes($Container) | ForEach-Object { $_.ToString("x2") }) -join "")
$uri = "vscode-remote://attached-container+$hex$Workspace"
Write-Host "opening VS Code (profile: $ProfileDir): $uri"
$prevContainerHost = $env:CONTAINER_HOST
$prevDockerHost    = $env:DOCKER_HOST
try {
    $env:CONTAINER_HOST = $url
    $env:DOCKER_HOST    = $url
    & code --user-data-dir $ProfileDir --extensions-dir $ExtDir --folder-uri $uri
} finally {
    $env:CONTAINER_HOST = $prevContainerHost
    $env:DOCKER_HOST    = $prevDockerHost
}
