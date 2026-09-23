#!/usr/bin/env bash
# devc-code.sh — open local VS Code windows attached to devc podman containers
# running on remote Linux servers, from Linux / macOS — without touching your
# local podman setup. Multiple servers can be connected at once.
#
# Why a separate tool (same reasons as the Windows devc-code.ps1):
#   - `devc code` on the server has no GUI to open, and a server's podman is the
#     wrong one to attach to from your desktop.
#   - We must NOT change your local podman default connection (that would break
#     local `devc`). Instead we tunnel each server's rootless podman socket to a
#     local TCP port over OpenSSH, point podman at that tunnel for the launched
#     process only (CONTAINER_HOST/DOCKER_HOST), and start an isolated VS Code
#     instance (its own --user-data-dir, shared extensions) that inherits them.
#     Local podman and your main VS Code stay untouched.
#
# Multi-server: each --server gets its own tunnel on an automatically chosen
# free local port, so several servers stay connected simultaneously without
# colliding. The container picker then lists devc-* containers from EVERY
# connected server. Each server also gets its own VS Code profile
# (~/.devc-vscode/<server>) so the windows don't reuse one instance's stale
# CONTAINER_HOST.
#
# Nothing is hard-coded: --identity defaults from a config file
# (~/.devc-code.json), saved on first run. The remote uid (socket path) is
# discovered over ssh and cached per server.
#
# Usage:
#   devc-code.sh --server user@host          # open/reuse a tunnel, then pick a container
#   devc-code.sh                             # pick from all currently connected servers
#   devc-code.sh --container devc-myproj-1a2b3c4d
#   devc-code.sh --no-clean                  # re-focus without clearing the server
#   devc-code.sh --stop                      # stop ALL devc tunnels
#   devc-code.sh --server user@host --stop   # stop just that server's tunnel
#
# Server-side prerequisites (once, on each server):
#   cd ~/my-project && devc                       # create + start the container
#   systemctl --user enable --now podman.socket   # expose the rootless podman API
#   loginctl enable-linger "$USER"                # keep it up after you log out
set -euo pipefail

err()  { printf 'devc-code: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
usage() { sed -n '/^# Usage:/,/loginctl/p' "$0" | sed 's/^# \{0,1\}//'; }

# --- shared VS Code server cache ---------------------------------------------
# Every devc container mounts the named volume devc-vscode-server READ-ONLY at
# /opt/devc-vscode-server. It holds pristine, unpacked VS Code Server builds
# (bin/<commit>), so a new container doesn't pay for streaming ~200 MB of server
# into itself: before VS Code attaches we copy the matching build into
# ~/.vscode-server/bin locally, and VS Code finds it already installed.
#
# Only the host writes the volume: a throwaway container (no network, volume rw)
# unpacks the tarball VS Code itself downloaded on this host
# (/tmp/vsch-$USER/serverCache). Read-only in the dev containers, because what
# lands there gets executed in every other container - one compromised by a
# prompt injection must not be able to plant a server for all of them. For the
# same reason extensions are not cached: a snapshot could only come from inside
# a container. Builds older than 30 days (since fill) are pruned on the next
# fill. Containers created without the volume simply skip the whole thing.
VSCODE_VOL=devc-vscode-server
VSCODE_MNT=/opt/devc-vscode-server

# Runs as root in the throwaway filler container, volume at /cache, tarball on stdin.
VSCODE_FILL='
commit=$1; c=/cache/bin
mkdir -p "$c" || exit 1
find "$c" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null
# a build counts only if complete (product.json); drop leftovers of a bad copy
[ -f "$c/$commit/product.json" ] && exit 0
rm -rf "$c/$commit"
t="$c/.$commit.$$"
if mkdir -p "$t" && tar --no-same-owner -xz -C "$t"; then
    # the tarball holds a single top-level dir (vscode-server-linux-<arch>/)
    s=$(find "$t" -maxdepth 2 -name product.json | head -n1)
    [ -n "$s" ] && mv -T "$(dirname "$s")" "$c/$commit" && touch "$c/$commit"
fi
rm -rf "$t"
[ -f "$c/$commit/product.json" ]
'

# Runs as dev in the dev container: copy the cached build into ~/.vscode-server.
VSCODE_COPY='
commit=$1; c=$2/bin/$1; b=$HOME/.vscode-server/bin/$1
# drop the symlink into the shared rw volume left by the first cache version
e=$HOME/.vscode-server/extensionsCache
[ -L "$e" ] && case "$(readlink "$e")" in /opt/vscode-cache*) rm -f "$e" ;; esac
[ -f "$c/product.json" ] || exit 0
[ -f "$b/product.json" ] && exit 0
rm -rf "$b"; mkdir -p "${b%/*}" || exit 0
cp -a "$c" "$b.$$" && mv -T "$b.$$" "$b"
rm -rf "$b.$$"
exit 0
'

# seed_vscode_server CODE_BIN CONTAINER PODMAN_CMD... - best effort, never fails.
seed_vscode_server() {
    local code_bin="$1" ctr="$2"; shift 2
    local commit probe arch tar img
    commit="$("$code_bin" --version 2>/dev/null | sed -n 2p)" || return 0
    [ -n "$commit" ] || return 0
    probe="$("$@" exec "$ctr" sh -c \
        'uname -m; [ -d "$2" ] && echo vol; [ -f "$2/bin/$1/product.json" ] && echo cached; true' \
        sh "$commit" "$VSCODE_MNT" 2>/dev/null)" || return 0
    case "$probe" in *vol*) ;; *) return 0 ;; esac
    case "$probe" in
        *cached*) ;;
        *)  case "$(printf '%s' "$probe" | head -n1)" in
                x86_64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=armhf ;; *) return 0 ;;
            esac
            tar="/tmp/vsch-$(id -un)/serverCache/$commit/vscode-server-linux-$arch.tar.gz"
            [ -f "$tar" ] || return 0
            # same image as the container: it's there already and has sh + tar
            img="$("$@" inspect -f '{{.Image}}' "$ctr" 2>/dev/null)" || return 0
            "$@" run --rm -i --network none --user 0 --entrypoint sh \
                -v "$VSCODE_VOL:/cache" "$img" -c "$VSCODE_FILL" sh "$commit" \
                <"$tar" >/dev/null 2>&1 || return 0 ;;
    esac
    "$@" exec "$ctr" sh -c "$VSCODE_COPY" sh "$commit" "$VSCODE_MNT" >/dev/null 2>&1 || true
}

# --- defaults ------------------------------------------------------------------
CODE_BIN="${DEVC_CODE_BIN:-code}"          # VSCodium/insiders: DEVC_CODE_BIN=codium
CONFIG_PATH="${DEVC_CODE_CONFIG:-$HOME/.devc-code.json}"
EXT_DIR="$HOME/.vscode/extensions"
WORKSPACE="/workspace"
BASE_PORT=8889
LOCAL_PORT=0            # force a specific port for a NEW tunnel; 0 = pick a free one
SERVER=""
IDENTITY=""
CONTAINER=""
PROFILE_DIR=""
PROFILE_DIR_SET=0
STOP=0
NOCLEAN=0

# --- args ----------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --server)      SERVER="$2"; shift 2 ;;
        --identity|-i) IDENTITY="$2"; shift 2 ;;
        --local-port)  LOCAL_PORT="$2"; shift 2 ;;
        --base-port)   BASE_PORT="$2"; shift 2 ;;
        --container)   CONTAINER="$2"; shift 2 ;;
        --workspace)   WORKSPACE="$2"; shift 2 ;;
        --profile-dir) PROFILE_DIR="$2"; PROFILE_DIR_SET=1; shift 2 ;;
        --ext-dir)     EXT_DIR="$2"; shift 2 ;;
        --no-clean)    NOCLEAN=1; shift ;;
        --stop)        STOP=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown arg: $1 (try --help)" ;;
    esac
done

# --- config helpers ------------------------------------------------------------
# Config JSON (shared with devc-code.ps1): { "Server", "Identity", "Sockets":{} }
cfg_get() {  # KEY -> scalar string value (Server/Identity)
    [ -f "$CONFIG_PATH" ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$CONFIG_PATH" "$1" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
v = d.get(sys.argv[2])
if isinstance(v, str): print(v)
PY
    else
        grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_PATH" 2>/dev/null \
            | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
    fi
}

# Per-server podman socket path, cached in the config. The path only depends on
# the remote uid, so once discovered it never changes — caching it lets repeat
# runs skip the discovery ssh, so a password server is asked for the password
# just once (at the tunnel) instead of twice.
declare -A SOCKETS=()
CFG_DIRTY=0
if [ -f "$CONFIG_PATH" ] && command -v python3 >/dev/null 2>&1; then
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        SOCKETS["$k"]="$v"
    done < <(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
for k, v in (d.get("Sockets") or {}).items():
    print(f"{k}\t{v}")
PY
)
fi

save_config() {  # write Server/Identity/Sockets, preserving the socket cache
    local args=() k
    for k in "${!SOCKETS[@]}"; do args+=("$k" "${SOCKETS[$k]}"); done
    if command -v python3 >/dev/null 2>&1; then
        # sockets are passed as trailing "key value key value ..." argv pairs; the
        # program itself comes from the heredoc on stdin (`python3 -`).
        python3 - "$CONFIG_PATH" "$SERVER" "$IDENTITY" "${args[@]}" <<'PY'
import json, sys
path, server, identity = sys.argv[1], sys.argv[2], sys.argv[3]
rest = sys.argv[4:]
sockets = dict(zip(rest[0::2], rest[1::2]))
json.dump({"Server": server, "Identity": identity, "Sockets": sockets},
          open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
    else
        # no python3: write a flat config without the socket cache
        printf '{\n  "Server": "%s",\n  "Identity": "%s"\n}\n' "$SERVER" "$IDENTITY" > "$CONFIG_PATH"
    fi
}

# --- config: arg > config file > fallback --------------------------------------
[ -n "$IDENTITY" ] || IDENTITY="$(cfg_get Identity)"
[ -n "$IDENTITY" ] || IDENTITY="$HOME/.ssh/id_ed25519"

# ssh identity is optional: only pass -i if the file exists, else rely on agent/config
ssh_opts=()
[ -f "$IDENTITY" ] && ssh_opts=(-i "$IDENTITY")
# accept-new: auto-trust an unknown host key instead of the interactive yes/no
# prompt (which would otherwise stall the run).
hk_opts=(-o StrictHostKeyChecking=accept-new)

# `timeout` (coreutils; `gtimeout` on macOS) bounds a podman call so a silently
# dead tunnel can't hang us forever — see get_devc_names.
timeout_cmd=()
if   command -v timeout  >/dev/null 2>&1; then timeout_cmd=(timeout 10)
elif command -v gtimeout >/dev/null 2>&1; then timeout_cmd=(gtimeout 10); fi

# --- tunnel inventory: one ssh per connected server ----------------------------
# Each of our tunnels is `ssh ... -L <port>:<remote podman.sock> <server>`, so we
# can recover both the local port and the server it points at from the cmdline.
# Emits "port<TAB>server<TAB>pid" per tunnel. `ps axww` gives full, untruncated
# command lines on both Linux and macOS.
tunnels() {
    ps axww -o pid=,command= 2>/dev/null | while read -r pid cmd; do
        [ -n "$pid" ] || continue
        case "$cmd" in *ssh*) ;; *) continue ;; esac
        if [[ "$cmd" =~ -L[[:space:]]+([0-9]+):[^[:space:]]*podman\.sock[[:space:]]+([^[:space:]]+) ]]; then
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$pid"
        fi
    done
}

port_listening() {  # PORT
    local p="$1"
    if   command -v ss   >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q "[:.]$p "
    elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
    else (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; fi
}

free_port() {  # START -> a free local port at/after START
    local start="$1" used p
    used="$(tunnels | cut -f1)"
    for ((p=start; p<start+200; p++)); do
        printf '%s\n' "$used" | grep -qx "$p" && continue
        port_listening "$p" && continue
        echo "$p"; return 0
    done
    die "no free local port near $start"
}

# List one tunnel's devc-* containers, but never block forever on it. When a
# tunnel's ssh session has silently died the local port keeps listening, so
# `podman ... ps` connects and then hangs indefinitely (podman has no timeout) —
# which would freeze the whole picker on that one dead server. Prints the names;
# returns 1 (and prints nothing) if the tunnel was unresponsive.
get_devc_names() {  # URL
    local url="$1" out rc=0
    out="$("${timeout_cmd[@]}" podman --url "$url" ps --filter "name=devc-" --format '{{.Names}}' 2>/dev/null)" || rc=$?
    if [ "$rc" = 124 ] && [ "${#timeout_cmd[@]}" -gt 0 ]; then return 1; fi
    printf '%s\n' "$out" | sed '/^$/d'
    return 0
}

# --- ensure (or reuse) a tunnel for a given server -----------------------------
connect_server() {  # SRV FORCE_PORT(0=auto)
    local srv="$1" force="${2:-0}" existing socket port i
    existing="$(tunnels | awk -F'\t' -v s="$srv" '$2==s{print $1; exit}')"
    if [ -n "$existing" ]; then
        err "tunnel to $srv already up on $existing"
        return 0
    fi
    socket="${SOCKETS[$srv]:-}"
    if [ -z "$socket" ]; then
        socket="$(ssh "${ssh_opts[@]}" "${hk_opts[@]}" "$srv" 'printf "/run/user/%s/podman/podman.sock" "$(id -u)"' 2>/dev/null)" \
            || die "cannot ssh to $srv ($IDENTITY / password) — check 'ssh $srv'."
        [ -n "$socket" ] || die "could not discover the remote podman socket on $srv."
        SOCKETS["$srv"]="$socket"
        CFG_DIRTY=1
    fi
    if [ "$force" != 0 ]; then port="$force"; else port="$(free_port "$BASE_PORT")"; fi
    err "opening tunnel $port -> $srv:$socket"
    # -fN: authenticate in this terminal (so a password prompt is visible), then
    # fork to the background once the forward is up. ExitOnForwardFailure makes a
    # non-zero exit here mean the forward failed.
    ssh "${ssh_opts[@]}" "${hk_opts[@]}" -fN \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -L "${port}:${socket}" "$srv" \
        || die "tunnel did not come up on $port — check that 'ssh $srv' works."
    for i in $(seq 1 40); do port_listening "$port" && break; sleep 0.25; done
    port_listening "$port" || die "tunnel did not come up on $port — check that 'ssh $srv' works."
}

# --- --stop: close devc tunnels (all, or just --server's) ----------------------
if [ "$STOP" = 1 ]; then
    stopped=0
    while IFS=$'\t' read -r port srv tpid; do
        [ -n "$port" ] || continue
        [ -z "$SERVER" ] || [ "$srv" = "$SERVER" ] || continue
        kill "$tpid" 2>/dev/null && { err "stopped tunnel $port -> $srv"; stopped=$((stopped + 1)); }
    done < <(tunnels)
    [ "$stopped" -gt 0 ] || err "no devc tunnels running${SERVER:+ for $SERVER}"
    exit 0
fi

# nothing up yet and no --server: fall back to the saved server for a quick start
if [ -z "$SERVER" ] && [ -z "$(tunnels)" ]; then
    saved="$(cfg_get Server)"
    if [ -n "$saved" ]; then SERVER="$saved"; err "no tunnels up; connecting to saved server $SERVER"; fi
fi

# --- 1) bring up / reuse the tunnel for --server (port chosen automatically) ---
if [ -n "$SERVER" ]; then
    connect_server "$SERVER" "$LOCAL_PORT"
    if [ ! -f "$CONFIG_PATH" ] || [ "$CFG_DIRTY" = 1 ]; then
        save_config; err "saved defaults to $CONFIG_PATH"
    fi
fi

# --- 2) gather devc-* containers from EVERY connected server -------------------
command -v podman >/dev/null 2>&1 || die "podman client not found on PATH (needed to talk to the tunnel)."
[ -n "$(tunnels)" ] || die "no connected servers. Run with --server user@host to open one."

all=()   # rows: "server<TAB>port<TAB>url<TAB>name"
while IFS=$'\t' read -r port srv tpid; do
    [ -n "$port" ] || continue
    url="tcp://127.0.0.1:$port"
    if ! names_out="$(get_devc_names "$url")"; then
        # Port listens but forwards nowhere (dead ssh session). Tear it down so a
        # later `--server $srv` run rebuilds it cleanly, then skip it instead of
        # hanging the whole picker on this one server.
        err "WARNING: tunnel $port -> $srv is unresponsive; tearing it down. Reconnect with: $0 --server $srv"
        kill "$tpid" 2>/dev/null || true
        continue
    fi
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        all+=("$srv"$'\t'"$port"$'\t'"$url"$'\t'"$n")
    done <<< "$names_out"
done < <(tunnels)

[ "${#all[@]}" -gt 0 ] || die "no running devc-* containers on any connected server."

# --- 3) pick the container (across all servers) --------------------------------
pick=""
if [ -n "$CONTAINER" ]; then
    cand=()
    for row in "${all[@]}"; do
        rsrv="$(printf '%s' "$row" | cut -f1)"
        rname="$(printf '%s' "$row" | cut -f4)"
        [ "$rname" = "$CONTAINER" ] || continue
        [ -z "$SERVER" ] || [ "$rsrv" = "$SERVER" ] || continue
        cand+=("$row")
    done
    case "${#cand[@]}" in
        0) die "container '$CONTAINER' not visible on any connected server." ;;
        1) pick="${cand[0]}" ;;
        *) srvs=""; for r in "${cand[@]}"; do srvs="$srvs $(printf '%s' "$r" | cut -f1)"; done
           die "container '$CONTAINER' exists on multiple servers ($srvs ) — add --server to disambiguate." ;;
    esac
elif [ "${#all[@]}" = 1 ]; then
    pick="${all[0]}"
else
    err "containers on connected servers:"
    for i in "${!all[@]}"; do
        err "  [$i] $(printf '%s' "${all[$i]}" | cut -f4)  ($(printf '%s' "${all[$i]}" | cut -f1))"
    done
    printf 'select #: ' >&2; read -r sel
    pick="${all[$sel]:-}"; [ -n "$pick" ] || die "invalid selection."
fi

PICK_SERVER="$(printf '%s' "$pick" | cut -f1)"
URL="$(printf '%s' "$pick" | cut -f3)"
CONTAINER="$(printf '%s' "$pick" | cut -f4)"
err "ok: '$CONTAINER' on $PICK_SERVER reachable via $URL"

# per-server VS Code profile (unless explicitly overridden) so each server runs
# as its own instance with its own CONTAINER_HOST — a shared profile would make
# `code` hand the new window to an already-running instance with the wrong host.
if [ "$PROFILE_DIR_SET" != 1 ]; then
    key="$(printf '%s' "$PICK_SERVER" | sed 's/[^A-Za-z0-9]/_/g')"
    PROFILE_DIR="$HOME/.devc-vscode/$key"
fi

# --- 4) clear any hung VS Code server in the container (fixes "never connects") -
# A stale/orphaned vscode-server `node` process (e.g. left by a dropped session)
# makes a fresh attach hang forever. Restarting the whole container clears it, but
# that also kills everything else running inside. Instead, kill just the server
# processes and remove the server deployment so VS Code respawns one cleanly on
# attach; your running work in the container survives. No-op on a healthy first
# connect.
#
# We remove bin/ (and the IPC sockets), not just the *.lock files: after we kill
# the old server's node process, VS Code's incoming connection would otherwise
# find the old agent's recorded pid/pgid, try to reap it with `kill -9 -<pgid>`,
# and since the process is gone the pgid resolves to 0 -> `kill -9 -0` SIGKILLs
# the attach's own process group. Nuking bin/ leaves no phantom agent to reap.
# extensions/ is kept, so remote extensions are not re-installed; only the server
# binary re-downloads.
#
# NOTE: if you have a working window already attached to this container, this will
# drop that session — pass --no-clean to just re-focus it instead.
if [ "$NOCLEAN" != 1 ]; then
    err "clearing any stale VS Code server in '$CONTAINER'"
    podman --url "$URL" exec "$CONTAINER" /bin/sh -c '
pkill -TERM -f "/.vscode-server/" 2>/dev/null || true
sleep 1
pkill -KILL -f "/.vscode-server/" 2>/dev/null || true
rm -rf "$HOME/.vscode-server/bin" 2>/dev/null || true
rm -f /tmp/vscode-ipc-*.sock "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/vscode-ipc-*.sock 2>/dev/null || true
exit 0
' 2>/dev/null || true
fi

# --- 4b) pre-seed the VS Code server from the server's shared cache volume -----
# (see devc: seed_vscode_server). Restores bin/ right after the cleanup above, so
# neither a fresh container nor a re-attach has to stream the server in again.
command -v "$CODE_BIN" >/dev/null 2>&1 && \
    seed_vscode_server "$CODE_BIN" "$CONTAINER" podman --url "$URL"

# --- 5) isolated VS Code profile: seed once from your main profile + dockerPath -
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

# --- 6) point podman at the tunnel for THIS launch only, then open VS Code ------
command -v "$CODE_BIN" >/dev/null 2>&1 || die "'$CODE_BIN' not found on PATH (set DEVC_CODE_BIN to your VS Code CLI)."
hex="$(printf '%s' "$CONTAINER" | od -An -tx1 | tr -d ' \n')"
uri="vscode-remote://attached-container+${hex}${WORKSPACE}"
err "opening VS Code (profile: $PROFILE_DIR): $uri"
CONTAINER_HOST="$URL" DOCKER_HOST="$URL" \
    "$CODE_BIN" --user-data-dir "$PROFILE_DIR" --extensions-dir "$EXT_DIR" --folder-uri "$uri"
