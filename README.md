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
| `devc`          | Launcher for **Linux / macOS** (bash)                          |
| `devc.ps1`      | Launcher for **Windows** (PowerShell)                          |
| `devc-code.sh`  | Attach Linux / macOS VS Code to a container on a **remote server** |
| `devc-code.ps1` | Attach Windows VS Code to a container on a **remote server**   |
| `install.sh`    | Installer for Linux / macOS                                    |
| `install.ps1`   | Installer for Windows                                          |
| `devc-gui.ps1`  | Windows GUI to manage local + remote devc containers ([below](#gui-manage-containers-from-the-taskbar-devc-guips1)) |
| `devc-gui.lib.ps1` | Data/action layer shared by the GUI and its worker threads |
| `gen_gui_icon.py`  | Regenerates the GUI icon (`devc-gui.ico`)                  |

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

## Remote server: VS Code from your desktop (`devc-code.sh` / `devc-code.ps1`)

Run the container on a Linux **server** and attach your **local** VS Code to it,
from a Linux/macOS desktop (`devc-code.sh`) or Windows (`devc-code.ps1`). This
needs its own tool because:

- `devc code` *on the server* has no GUI to open, and VS Code has no CLI to attach
  to a container nested inside a Remote-SSH session — so attaching has to be
  driven from the desktop, against the server's podman.
- (Windows only) podman's own ssh client is broken for this (drops the host:
  `dial tcp :22 ... refused`).

Both scripts work around it the same way: they tunnel the server's rootless
podman socket to a local TCP port over **OpenSSH**, point podman at that tunnel
for a single process only, and open an **isolated** VS Code instance attached to
the container. Your local podman default connection and your main VS Code are
left untouched.

**On the server (once):**
```bash
cd ~/my-project && devc                        # create + start the container
systemctl --user enable --now podman.socket    # expose the rootless podman API
loginctl enable-linger "$USER"                 # keep it up after you log out
```

### From Linux / macOS (`devc-code.sh`)

**You need:** OpenSSH with key access (`ssh user@server` works passwordless), the
`podman` client, and VS Code + the Dev Containers extension. The script sets
`dev.containers.dockerPath: podman` in its own VS Code profile, so you don't
have to.

```bash
# open/reuse a tunnel to a server (identity is saved to ~/.devc-code.json)
./devc-code.sh --server user@server

# later: just run it, then pick the container from ALL connected servers
devc-code.sh

# connect a second server too — both stay up, the picker lists containers from both
devc-code.sh --server user@other-server

devc-code.sh --container devc-myproj-1a2b3c4d   # skip the picker
devc-code.sh --stop                             # stop ALL devc tunnels
devc-code.sh --server user@server --stop        # stop just that server's tunnel
```

Multiple servers can be connected at once: each `--server` opens its own tunnel on
an automatically chosen free port and gets its own VS Code profile. Options:
`--identity <keyfile>` (default `~/.ssh/id_ed25519`), `--local-port` (force a port
for a new tunnel), `--workspace`, `--no-clean`. Using VSCodium/Insiders?
`DEVC_CODE_BIN=codium devc-code.sh`.

### From Windows (`devc-code.ps1`)

**You need:** OpenSSH with key access (`ssh user@server` works passwordless), the
podman client, and VS Code + the Dev Containers extension. (The script sets
`dev.containers.dockerPath: podman` in its own VS Code profile, so you don't
have to.)

```powershell
# first run: pass the server once — it's saved to %USERPROFILE%\.devc-code.json
.\devc-code.ps1 -Server user@server

# later: just run it, then pick the container from the list found on the server
.\devc-code.ps1

.\devc-code.ps1 -Container devc-myproj-1a2b3c4d   # skip the picker
.\devc-code.ps1 -Stop                             # close the ssh tunnel
```

Nothing is hard-coded in either: server / identity / local-port come from the
config file, the remote uid (socket path) is discovered over ssh, and the
container is chosen from the running `devc-*` containers on the server.

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
- **`--userns` error on Windows/macOS** — remove `--userns=keep-id:uid=1000,gid=1000`
  from the create args in the script (it's mainly for correct file ownership on
  rootless Linux).
- **Files / `~/.claude` / `/workspace` owned by the wrong user (Linux)** — the
  `devc` script maps your host user onto the image's `dev` user (uid 1000) via
  `--userns=keep-id:uid=1000,gid=1000`, so bind-mounts line up no matter what
  your host uid is. If you have an **older** container created before this (plain
  `--userns=keep-id`) and your host uid isn't 1000, `dev` can't read your mounted
  `~/.claude` (mode 700) or write `/workspace` — recreate it with `devc rm` then
  `devc` (or `devc code`). Ensure your podman is rootless.
- **Your desktop VS Code can't see a container running on a server** — don't run
  `devc code` on the server; drive the attach from your desktop with
  [`devc-code.sh`](#from-linux--macos-devc-codesh) (Linux/macOS) or
  [`devc-code.ps1`](#from-windows-devc-codeps1) (Windows). Plain `devc code` / a
  podman ssh connection won't work (see that section).
- **`ERRO ... graph driver "overlay" overwritten by ... "vfs"`** — harmless for
  this workflow. It's the *server's* local podman client warning that its store
  was first initialised with `vfs`; the remote API (the socket the tunnel uses)
  and your containers still work. To silence it, pin the driver by adding
  `[storage]`/`driver = "vfs"` to `~/.config/containers/storage.conf` on the
  server, or migrate to overlay with a `podman system reset` (wipes containers).
- **VS Code under snap/flatpak (Linux)** — these rewrite `$HOME`; the bash script
  already resolves the real home via `getent`, so `~/.claude` mounts correctly.

## GUI: manage containers from the taskbar (`devc-gui.ps1`)

A **Windows-only** WinForms front end for everything above: it shows every
`devc-*` container — **local and on connected remote servers** — in one table and
lets you start / stop / restart / open a shell / attach VS Code / view logs /
remove, without typing commands.

```powershell
# run it (visible console, handy while trying it out)
powershell -ExecutionPolicy Bypass -File .\devc-gui.ps1
```

Then **Tools → Pin to taskbar** creates a shortcut that launches it hidden (no
console flash) with its own icon; right-click the taskbar entry to pin it.

What it does:

- **Remote servers** are read over the same OpenSSH tunnels `devc-code.ps1` opens
  (it discovers them from the running `ssh.exe` processes — no state file), via
  podman's REST API with a real timeout, so a dead tunnel is shown as
  `unresponsive` and torn down instead of hanging the window.
- **Local** containers are read with the `podman` CLI.
- **VS Code attach** (button or double-click a row) is delegated to
  `devc-code.ps1` (remote) / `devc.ps1 code` (local) unchanged — all the tuned
  workarounds still apply. It opens in a visible console so a password prompt has
  somewhere to go.
- **Connect server…** opens a tunnel to a key-auth server silently; for a
  password-only server it asks for the password in a dialog and feeds it to ssh
  via `SSH_ASKPASS` (no console needed). If your OpenSSH build ignores askpass or
  the password is wrong, it falls back to a visible console you can type into.
- A **filter box** (top right) narrows the table live as you type (matches any
  column). **Right-click a row** to *Open containing folder* (Explorer), *Copy
  path*, or *Copy container name*; local `/mnt/c/...` mount paths are translated
  back to `C:\...`, and the open action is disabled for remote (server) rows.
- Reads run on background threads, so the window stays responsive; there is **no
  auto-refresh** — hit **Refresh** (it also refreshes after each action).

Requires Windows PowerShell 5.1 (the default `powershell.exe`), the `podman`
client, and — for VS Code attach — VS Code with the Dev Containers extension.
Needs no administrator rights. Regenerate the icon with
`python gen_gui_icon.py` (needs Pillow).
