#!/usr/bin/env bash
# devc-code.sh — open a local VS Code window attached to a devc podman container
# running on a remote Linux server, from Linux / macOS — without touching your
# local podman setup.
#
# Why a separate tool (same reasons as the Windows devc-code.ps1):
#   - `devc code` on the server has no GUI to open, and a server's podman is the
#     wrong one to attach to from your desktop.
#   - We must NOT change your local podman default connection (that would break
#     local `devc`). Instead we tunnel the server's rootless podman socket to a
#     local TCP port over OpenSSH, point podman at that tunnel for the launched
#     process only (CONTAINER_HOST/DOCKER_HOST), and start an isolated VS Code
#     instance (its own --user-data-dir, shared extensions) that inherits them.
#     Local podman and your main VS Code stay untouched.
#
# Nothing is hard-coded: --server / --identity / --local-port are read from a
# config file (~/.devc-code.json) and saved there on first run, so later you can
# just run `devc-code.sh`. The remote uid (socket path) is discovered over ssh.
# If --container is omitted you pick from the devc-* containers on the server.
#
# Usage:
#   devc-code.sh --server user@host          # first run: saves config, pick container
#   devc-code.sh                             # later: uses saved config
#   devc-code.sh --container devc-myproj-1a2b3c4d
#   devc-code.sh --stop                      # close the ssh tunnel
#
# Server-side prerequisites (once, on the server):
#   cd ~/my-project && devc                       # create + start the container
#   systemctl --user enable --now podman.socket   # expose the rootless podman API
#   loginctl enable-linger "$USER"                # keep it up after you log out
set -euo pipefail

err()  { printf 'devc-code: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- defaults ------------------------------------------------------------------
CODE_BIN="${DEVC_CODE_BIN:-code}"          # VSCodium/insiders: DEVC_CODE_BIN=codium
CONFIG_PATH="${DEVC_CODE_CONFIG:-$HOME/.devc-code.json}"
PROFILE_DIR="$HOME/.devc-vscode"
EXT_DIR="$HOME/.vscode/extensions"
WORKSPACE="/workspace"
LOCAL_PORT=0
SERVER=""
IDENTITY=""
CONTAINER=""
STOP=0

# --- args ----------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --server)     SERVER="$2"; shift 2 ;;
        --identity|-i) IDENTITY="$2"; shift 2 ;;
        --local-port) LOCAL_PORT="$2"; shift 2 ;;
        --container)  CONTAINER="$2"; shift 2 ;;
        --workspace)  WORKSPACE="$2"; shift 2 ;;
        --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
        --ext-dir)    EXT_DIR="$2"; shift 2 ;;
        --stop)       STOP=1; shift ;;
        -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown arg: $1 (try --help)" ;;
    esac
done

# --- config: arg > config file > fallback --------------------------------------
cfg_get() {  # cfg_get KEY -> value from the flat JSON config (handles "str" or bare number)
    [ -f "$CONFIG_PATH" ] || return 0
    grep -oP "\"$1\"\s*:\s*\K(\"[^\"]*\"|[^,}\s]+)" "$CONFIG_PATH" 2>/dev/null \
        | head -1 | sed 's/^"//; s/"$//'
}
[ -n "$SERVER" ]   || SERVER="$(cfg_get Server)"
[ -n "$IDENTITY" ] || IDENTITY="$(cfg_get Identity)"
if [ "$LOCAL_PORT" = 0 ]; then
    LOCAL_PORT="$(cfg_get LocalPort)"; [ -n "$LOCAL_PORT" ] || LOCAL_PORT=8889
fi
[ -n "$IDENTITY" ] || IDENTITY="$HOME/.ssh/id_ed25519"

URL="tcp://127.0.0.1:$LOCAL_PORT"

# matches our -L forward (port:/run/user/<uid>/podman/podman.sock) in a cmdline
fwd_rx="${LOCAL_PORT}:/run/.*podman\.sock"
tunnel_pids() { pgrep -f -- "-L *$fwd_rx" 2>/dev/null || true; }

# --- --stop --------------------------------------------------------------------
if [ "$STOP" = 1 ]; then
    pids="$(tunnel_pids)"
    if [ -n "$pids" ]; then kill $pids && err "tunnel on $LOCAL_PORT stopped"
    else err "no tunnel on $LOCAL_PORT"; fi
    exit 0
fi

[ -n "$SERVER" ] || die "no server. Pass --server user@host once (saved to $CONFIG_PATH), then just run the script."

# ssh identity is optional: only pass -i if the file exists, else rely on agent/config
ssh_opts=()
[ -f "$IDENTITY" ] && ssh_opts=(-i "$IDENTITY")

# --- 1) ensure the ssh tunnel  local:$LOCAL_PORT -> remote podman socket --------
port_listening() {
    if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q ":$LOCAL_PORT "
    else (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; fi
}

if [ -n "$(tunnel_pids)" ]; then
    err "tunnel already running on $LOCAL_PORT"
else
    socket="$(ssh "${ssh_opts[@]}" "$SERVER" 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"' 2>/dev/null)" \
        || die "cannot ssh to $SERVER — check 'ssh $SERVER' works."
    [ -n "$socket" ] || die "could not discover the remote podman socket on $SERVER."

    err "opening tunnel $LOCAL_PORT -> $SERVER:$socket"
    # -f: background after the forward is established (so a non-zero exit here
    # means the forward failed, thanks to ExitOnForwardFailure).
    ssh "${ssh_opts[@]}" -fN \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -L "${LOCAL_PORT}:${socket}" \
        "$SERVER" \
        || die "tunnel did not come up on $LOCAL_PORT (is the podman socket enabled on the server? systemctl --user enable --now podman.socket)."

    for _ in $(seq 1 40); do port_listening && break; sleep 0.25; done
    port_listening || die "tunnel port $LOCAL_PORT is not listening."
fi

# remember connection settings for next time (container intentionally not saved)
if [ ! -f "$CONFIG_PATH" ]; then
    printf '{\n  "Server": "%s",\n  "Identity": "%s",\n  "LocalPort": %s\n}\n' \
        "$SERVER" "$IDENTITY" "$LOCAL_PORT" > "$CONFIG_PATH"
    err "saved defaults to $CONFIG_PATH"
fi

# --- 2) pick / verify the container (explicit --url, never touches default) -----
command -v podman >/dev/null 2>&1 || die "podman client not found on PATH (needed to talk to the tunnel)."
mapfile -t names < <(podman --url "$URL" ps --filter "name=devc-" --format '{{.Names}}' 2>/dev/null | sed '/^$/d')

if [ -z "$CONTAINER" ]; then
    case "${#names[@]}" in
        0) die "no running devc-* containers on $SERVER (start one with 'devc' on the server)." ;;
        1) CONTAINER="${names[0]}" ;;
        *) err "containers on $SERVER:"
           for i in "${!names[@]}"; do err "  [$i] ${names[$i]}"; done
           printf 'select #: ' >&2; read -r sel
           CONTAINER="${names[$sel]:-}"; [ -n "$CONTAINER" ] || die "invalid selection." ;;
    esac
fi

found=0; for n in "${names[@]}"; do [ "$n" = "$CONTAINER" ] && found=1; done
[ "$found" = 1 ] || die "container '$CONTAINER' not visible through the tunnel. Is it running on the server?"
err "ok: '$CONTAINER' reachable through the tunnel"

# --- 3) isolated VS Code profile: seed once from your main profile + dockerPath -
prof_user="$PROFILE_DIR/User"
mkdir -p "$prof_user"
settings="$prof_user/settings.json"

# locate the main VS Code user dir (Linux vs macOS)
if [ "$(uname -s)" = "Darwin" ]; then
    main_user="$HOME/Library/Application Support/Code/User"
else
    main_user="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
fi
if [ ! -f "$settings" ]; then
    [ -f "$main_user/settings.json" ] && cp "$main_user/settings.json" "$settings" || echo '{}' > "$settings"
    [ -f "$main_user/keybindings.json" ] && cp "$main_user/keybindings.json" "$prof_user/keybindings.json" || true
fi

# ensure dev.containers.dockerPath = podman in the isolated settings
if ! grep -q 'dev\.containers\.dockerPath' "$settings"; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$settings" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f: data = json.load(f)
except Exception:
    data = {}
data["dev.containers.dockerPath"] = "podman"
with open(p, "w") as f: json.dump(data, f, indent=4)
PY
    else
        # naive fallback: insert after the first '{'
        body="$(cat "$settings")"
        case "$(printf '%s' "$body" | tr -d '[:space:]')" in
            ""|"{}") printf '{\n    "dev.containers.dockerPath": "podman"\n}\n' > "$settings" ;;
            *)       printf '%s' "$body" | sed '0,/{/s//{\n    "dev.containers.dockerPath": "podman",/' > "$settings" ;;
        esac
    fi
fi

# --- 4) point podman at the tunnel for THIS launch only, then open VS Code ------
command -v "$CODE_BIN" >/dev/null 2>&1 || die "'$CODE_BIN' not found on PATH (set DEVC_CODE_BIN to your VS Code CLI)."
hex="$(printf '%s' "$CONTAINER" | od -An -tx1 | tr -d ' \n')"
uri="vscode-remote://attached-container+${hex}${WORKSPACE}"
err "opening VS Code (profile: $PROFILE_DIR): $uri"
CONTAINER_HOST="$URL" DOCKER_HOST="$URL" \
    "$CODE_BIN" --user-data-dir "$PROFILE_DIR" --extensions-dir "$EXT_DIR" --folder-uri "$uri"
