#!/usr/bin/env bash
# scripts/sync-quadlets-host.sh
# Copy host-specific quadlet overlay files into /etc/containers/systemd.

set -euo pipefail

REPO_DIR="/opt/gitops/repo"
QUADLET_DST="/etc/containers/systemd"
HOSTNAME="${HOSTNAME:-}"

if [ -z "$HOSTNAME" ]; then
  echo "HOSTNAME environment variable is required" >&2
  exit 1
fi

HOST_DIR="$REPO_DIR/quadlets/$HOSTNAME"
if [ ! -d "$HOST_DIR" ]; then
  echo "Host-specific quadlet directory not found: $HOST_DIR" >&2
  exit 2
fi

mkdir -p "$QUADLET_DST"

for src in "$HOST_DIR"/*; do
  [ -f "$src" ] || continue
  dst="$QUADLET_DST/$(basename "$src")"
  install -m 644 "$src" "$dst"
  echo "Installed host quadlet $(basename "$src")"
done

exit 0
