# Install devc on Windows (PowerShell). Usage:  .\install.ps1
$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$dest = Join-Path $env:USERPROFILE 'bin'

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    Write-Warning "podman not found. Install Podman Desktop or 'winget install RedHat.Podman', then run: podman machine init; podman machine start"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path (Join-Path $src 'devc.ps1') -Destination (Join-Path $dest 'devc.ps1') -Force
Write-Host "Installed devc.ps1 -> $dest\devc.ps1"

# Add a `devc` function to the PowerShell profile so you can call it like `devc code`.
$line = "function devc { & '$dest\devc.ps1' @args }"
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }
if (-not (Select-String -Path $PROFILE -SimpleMatch 'devc.ps1' -Quiet)) {
    Add-Content -Path $PROFILE -Value $line
    Write-Host "Added a 'devc' function to your PowerShell profile ($PROFILE)."
    Write-Host "Open a new terminal (or run: . `$PROFILE) to use it."
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1) podman machine init; podman machine start   # if not already running"
Write-Host "  2) devc build                                  # one-time base image build"
Write-Host "  3) cd <project>; devc                          # shell inside the container"
Write-Host "     devc code                                   # open VS Code attached inside it"
