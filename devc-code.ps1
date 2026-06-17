<#
.SYNOPSIS
  Open a VS Code window attached to a devc podman container running on a remote
  Linux server, from Windows - without touching your local podman setup.

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

  Nothing is hard-coded: -Server (and optional -Identity/-LocalPort) are read
  from a config file (default ~\.devc-code.json) and saved there on first run,
  so later you can just run `.\devc-code.ps1`. The remote uid (socket path) is
  discovered over ssh. If -Container is omitted you pick from the devc-*
  containers found on the server.

.PARAMETER Server
  ssh target: user@host, host, or an ssh config alias.

.EXAMPLE
  .\devc-code.ps1 -Server user@host              # first run: saves config
  .\devc-code.ps1                                # later: uses saved config, pick container
  .\devc-code.ps1 -Container devc-myproj-1a2b3c4d
  .\devc-code.ps1 -Stop
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Identity,
    [int]   $LocalPort  = 0,
    [string]$Container,
    [string]$Workspace  = "/workspace",
    [string]$ProfileDir = "$env:USERPROFILE\.devc-vscode",
    [string]$ExtDir     = "$env:USERPROFILE\.vscode\extensions",
    [string]$ConfigPath = "$env:USERPROFILE\.devc-code.json",
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

# --- config: param > config file > fallback ------------------------------------
$cfg = $null
if (Test-Path $ConfigPath) { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
if (-not $Server   -and $cfg -and $cfg.Server)    { $Server   = $cfg.Server }
if (-not $Identity -and $cfg -and $cfg.Identity)  { $Identity = $cfg.Identity }
if ($LocalPort -eq 0) { $LocalPort = if ($cfg -and $cfg.LocalPort) { [int]$cfg.LocalPort } else { 8889 } }
if (-not $Identity)   { $Identity  = "$env:USERPROFILE\.ssh\id_ed25519" }

$url   = "tcp://127.0.0.1:$LocalPort"
$fwdRx = "$LocalPort`:/run/.*podman\.sock"   # matches our -L forward in a cmdline

function Get-Tunnel {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
        Where-Object { $_.CommandLine -match $fwdRx }
}

if ($Stop) {
    $t = Get-Tunnel
    if ($t) { $t | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Host "tunnel on $LocalPort stopped" }
    else    { Write-Host "no tunnel on $LocalPort" }
    return
}

if (-not $Server) {
    Write-Error "no server. Pass -Server user@host once (it gets saved to $ConfigPath), then just run the script."
    return
}

$sshArgs = @("-i", $Identity)

# --- 1) ensure the ssh tunnel  local:$LocalPort -> remote podman socket --------
if (Get-Tunnel) {
    Write-Host "tunnel already running on $LocalPort"
} else {
    # discover the remote rootless podman socket path (uid is per-user)
    $socket = (& ssh @sshArgs $Server 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"' 2>$null)
    if (-not $socket) { Write-Error "cannot ssh to $Server (key: $Identity) - check 'ssh $Server'."; return }
    $socket = $socket.Trim()

    Write-Host "opening tunnel $LocalPort -> ${Server}:$socket"
    Start-Process ssh -WindowStyle Hidden -ArgumentList @(
        "-i", $Identity,
        "-N",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-L", "${LocalPort}:${socket}",
        $Server
    )
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if (Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue) { break }
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue)) {
        Write-Error "tunnel did not come up on $LocalPort - check the key ($Identity) and that 'ssh $Server' works."
        return
    }
}

# remember the connection settings for next time (container is intentionally not saved)
if (-not (Test-Path $ConfigPath)) {
    [pscustomobject]@{ Server = $Server; Identity = $Identity; LocalPort = $LocalPort } |
        ConvertTo-Json | Set-Content $ConfigPath
    Write-Host "saved defaults to $ConfigPath"
}

# --- 2) pick / verify the container (explicit --url, never touches default) ----
$names = @(& podman --url $url ps --filter "name=devc-" --format "{{.Names}}" 2>$null | Where-Object { $_ })
if (-not $Container) {
    if ($names.Count -eq 0)      { Write-Error "no running devc-* containers on $Server (start one with 'devc' on the server)."; return }
    elseif ($names.Count -eq 1)  { $Container = $names[0] }
    else {
        Write-Host "containers on ${Server}:"
        for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("  [{0}] {1}" -f $i, $names[$i]) }
        $sel = Read-Host "select #"
        $Container = $names[[int]$sel]
    }
}
if ($names -notcontains $Container) {
    Write-Error "container '$Container' not visible through the tunnel. Is it running on the server?"
    return
}
Write-Host "ok: '$Container' reachable through the tunnel"

# --- 3) isolated VS Code profile: seed once from your main profile + dockerPath -
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

# --- 4) point podman at the tunnel for THIS process only, then launch VS Code --
$env:CONTAINER_HOST = $url
$env:DOCKER_HOST    = $url
$hex = (([System.Text.Encoding]::ASCII.GetBytes($Container) | ForEach-Object { $_.ToString("x2") }) -join "")
$uri = "vscode-remote://attached-container+$hex$Workspace"
Write-Host "opening VS Code (profile: $ProfileDir): $uri"
& code --user-data-dir $ProfileDir --extensions-dir $ExtDir --folder-uri $uri
