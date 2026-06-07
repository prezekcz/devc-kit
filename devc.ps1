# devc.ps1 — run any project in a podman dev container (Windows / PowerShell port).
#
# Mirrors the Linux `devc` script. Spins up (and reuses) a persistent container
# for the current directory, bind-mounted at /workspace, with Python 3.12,
# Node 22 and the Claude Code CLI. Install more inside with apt-get / pip — the
# container persists until `devc.ps1 rm`.
#
# Usage:
#   devc.ps1                 start/attach a shell in the container for the cwd
#   devc.ps1 code            open VS Code attached inside the container
#   devc.ps1 claude [args]   run the Claude Code CLI inside the container
#   devc.ps1 run <cmd...>    run an arbitrary command inside the container
#   devc.ps1 build           (re)build the base image
#   devc.ps1 stop | rm | ls | help
#
# Prereq: podman machine running (`podman machine init` then `podman machine start`).
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'shell',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$IMAGE = 'devc-base:latest'

function Write-Devc($msg) { [Console]::Error.WriteLine("devc: $msg") }

# --- base image (single source of truth; built from stdin, no context needed) ---
$Dockerfile = @'
FROM python:3.12-bookworm

# --- system tooling (extend at runtime with: sudo apt-get install ...) ---
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl git ca-certificates sudo less vim nano \
        build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js (also required by the Claude Code CLI) ---
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code CLI ---
RUN npm install -g @anthropic-ai/claude-code

# --- non-root user with passwordless sudo + serial access (dialout) ---
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && usermod -aG dialout $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /workspace
CMD ["/bin/bash"]
'@

function Build-Image {
    Write-Devc "building $IMAGE ..."
    $Dockerfile | podman build -t $IMAGE -f - .
    if ($LASTEXITCODE -ne 0) { throw "image build failed" }
}

function Test-Image {
    podman image exists $IMAGE 2>$null
    return ($LASTEXITCODE -eq 0)
}

# --- stable container name from the project path ---
$ProjectDir = (Get-Location).Path
$Base = (Split-Path -Leaf $ProjectDir) -replace '[^A-Za-z0-9_.-]', '-'
$md5 = [System.Security.Cryptography.MD5]::Create()
$hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectDir))
$Hash = (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
$Container = "devc-$Base-$Hash"

function Test-Container {
    podman container exists $Container 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-Container {
    if (-not (Test-Image)) { Build-Image }
    if (-not (Test-Container)) {
        Write-Devc "creating container $Container for $ProjectDir"
        $userHome = $env:USERPROFILE
        $createArgs = @(
            'create',
            '--name', $Container,
            '--hostname', $Base,
            '--userns=keep-id',
            '-v', "${ProjectDir}:/workspace",
            '-w', '/workspace',
            '-e', 'PYTHONUNBUFFERED=1'
        )
        # Persist Claude Code auth/config across containers if present on host.
        if (Test-Path "$userHome\.claude")      { $createArgs += @('-v', "$userHome\.claude:/home/dev/.claude") }
        if (Test-Path "$userHome\.claude.json") { $createArgs += @('-v', "$userHome\.claude.json:/home/dev/.claude.json") }
        if (Test-Path "$userHome\.gitconfig")   { $createArgs += @('-v', "$userHome\.gitconfig:/home/dev/.gitconfig:ro") }
        # Extra podman flags via env var, e.g. publish a port for the host browser:
        #   $env:DEVC_ARGS = '-p 5000:5000'
        if ($env:DEVC_ARGS) { $createArgs += ($env:DEVC_ARGS -split '\s+') }
        $createArgs += @('-it', $IMAGE)
        podman @createArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "container create failed" }
    }
    $running = (podman inspect -f '{{.State.Running}}' $Container 2>$null)
    if ($running -ne 'true') { podman start $Container | Out-Null }
}

switch ($Command) {
    { $_ -in 'build', 'rebuild' } { Build-Image }
    { $_ -in 'ls', 'list' } {
        podman ps -a --filter 'name=^devc-' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    }
    'stop' {
        podman stop $Container | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Devc "stopped $Container" } else { Write-Devc 'not running' }
    }
    { $_ -in 'rm', 'remove' } {
        podman rm -f $Container | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Devc "removed $Container" } else { Write-Devc 'no such container' }
    }
    { $_ -in 'code', 'vscode' } {
        Ensure-Container
        $hex = (([System.Text.Encoding]::ASCII.GetBytes($Container) | ForEach-Object { $_.ToString('x2') }) -join '')
        code --folder-uri "vscode-remote://attached-container+$hex/workspace"
    }
    'claude' {
        Ensure-Container
        podman exec -it $Container claude @Rest
    }
    { $_ -in 'run', 'exec' } {
        if (-not $Rest) { Write-Devc 'run: need a command'; exit 1 }
        Ensure-Container
        podman exec -it $Container @Rest
    }
    { $_ -in 'shell', 'sh', 'bash' } {
        Ensure-Container
        podman exec -it $Container bash
    }
    { $_ -in 'help', '-h', '--help' } {
        Get-Content $PSCommandPath | Where-Object { $_ -match '^#' } |
            Select-Object -First 16 | ForEach-Object { $_ -replace '^#\s?', '' }
    }
    default { Write-Devc "unknown command: $Command (try: devc.ps1 help)"; exit 1 }
}
