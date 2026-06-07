# devc — portable dev-container launcher

Run **any** project in a persistent [podman](https://podman.io) dev container —
no `.devcontainer/` file per project required. The container bundles **Python
3.12 + Node 22 + the Claude Code CLI**, with a non-root `dev` user that has
passwordless `sudo`, so you can `apt-get`/`pip install` anything else and it
sticks until you remove the container.

One base image (`devc-base:latest`) is shared by every project; each project
gets its own persistent container named `devc-<folder>-<pathhash>`, with the
project bind-mounted at `/workspace`.

## Contents

| File          | Purpose                                   |
|---------------|-------------------------------------------|
| `devc`        | Launcher for **Linux / macOS** (bash)     |
| `devc.ps1`    | Launcher for **Windows** (PowerShell)     |
| `install.sh`  | Installer for Linux / macOS               |
| `install.ps1` | Installer for Windows                     |

## Prerequisites (all platforms)

1. **podman**
   - Linux: `sudo pacman -S podman` / `sudo apt install podman` (rootless works out of the box).
   - Windows / macOS: install Podman Desktop (or `winget install RedHat.Podman`), then once:
     ```
     podman machine init
     podman machine start
     ```
2. **VS Code** + the **Dev Containers** extension (only if you want `devc code`).
   Point the extension at podman — in VS Code `settings.json`:
   ```json
   "dev.containers.dockerPath": "podman"
   ```

## Install

### Linux / macOS
```bash
./install.sh                 # copies devc to ~/.local/bin (pass a dir to override)
devc build                   # one-time base image build (a few minutes)
```
If `~/.local/bin` isn't on your `PATH`, the installer tells you the line to add.

### Windows (PowerShell)
```powershell
.\install.ps1                # copies devc.ps1 to %USERPROFILE%\bin + adds a `devc` function
. $PROFILE                   # reload profile (or open a new terminal)
devc build                   # one-time base image build
```

## Usage

```
devc                 start/attach a shell in the container for the current dir
devc code            open VS Code attached inside the container at /workspace
devc claude [args]   run the Claude Code CLI inside the container
devc run <cmd...>    run an arbitrary command inside the container
devc build           (re)build the base image
devc stop            stop this project's container
devc rm              stop + remove this project's container
devc ls              list all devc containers
devc help
```
(On Windows it's the same, via the `devc` function the installer added — or call
`devc.ps1 <cmd>` directly.)

Typical flow:
```bash
cd ~/my-project
devc code            # creates+starts the container, opens VS Code inside it
```

## Networking (host access to ports)

- **Linux:** the container uses `--network host`, so any port your app binds
  (e.g. 5000) is reachable from the host immediately.
- **Windows / macOS:** podman runs in a VM, so host networking points at the VM,
  not your desktop. Either let VS Code's *attach* auto-forward ports, or publish
  explicitly:
  ```
  # bash:  DEVC_ARGS="-p 5000:5000" devc
  # pwsh:  $env:DEVC_ARGS = "-p 5000:5000"; devc
  ```

## Extra podman flags (`DEVC_ARGS`)

Applied at container **create** time. Examples:
```bash
DEVC_ARGS="--device=/dev/ttyACM0" devc     # pass a serial device (Linux)
DEVC_ARGS="-p 8080:8080" devc              # publish a port
```
The container is created once, so these take effect on first launch. To change
them: `devc rm` then relaunch.

## Customising the image

The Dockerfile is embedded inside the `devc` / `devc.ps1` script (one source of
truth, built from stdin). Edit the `dockerfile()` heredoc (bash) or the
`$Dockerfile` here-string (PowerShell), then `devc build` to rebuild. Existing
containers keep the old image until you `devc rm` and relaunch.

## What carries into the container

If present on the host, these are mounted so auth/config "just works":
`~/.claude`, `~/.claude.json`, `~/.gitconfig`.

## Troubleshooting

- **`devc code` does nothing / wrong folder** — make sure the Dev Containers
  extension is installed and `dev.containers.dockerPath` is `podman`.
- **`--userns=keep-id` error on Windows/macOS** — remove it from the create args
  in the script (it's mainly for correct file ownership on rootless Linux).
- **Files written in the container owned by the wrong user (Linux)** —
  `--userns=keep-id` handles this; ensure your podman is rootless.
- **VS Code under snap/flatpak (Linux)** — these rewrite `$HOME`; the bash script
  already resolves the real home via `getent`, so `~/.claude` mounts correctly.
