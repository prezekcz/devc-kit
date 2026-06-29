#!/usr/bin/env bash
# Install devc (Linux / macOS). Usage: ./install.sh [dest-dir]
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$HOME/.local/bin}"

command -v podman >/dev/null 2>&1 || {
    echo "WARNING: podman not found on PATH. Install it first (e.g. 'sudo pacman -S podman' / 'sudo apt install podman')." >&2
}

mkdir -p "$dest"
install -m 0755 "$src_dir/devc" "$dest/devc"
echo "Installed devc -> $dest/devc"
install -m 0755 "$src_dir/devc-code.sh" "$dest/devc-code.sh"
echo "Installed devc-code.sh -> $dest/devc-code.sh"

case ":$PATH:" in
    *":$dest:"*) ;;
    *) echo "NOTE: $dest is not on your PATH. Add to your shell rc:"
       echo "      export PATH=\"$dest:\$PATH\"" ;;
esac

echo
echo "Next steps:"
echo "  1) devc build      # one-time base image build (Python+Node+Claude CLI)"
echo "  2) cd <project> && devc        # shell inside the container"
echo "     devc code                   # open VS Code attached inside it"
