#!/usr/bin/env bash
# scripts/derive-hostname.sh
# Derive a stable host shortname from machine-id and set it via hostnamectl.

set -euo pipefail

PREFIX="zehru"
MACHINE_ID_FILE="/etc/machine-id"

if [ ! -r "$MACHINE_ID_FILE" ]; then
  echo "machine-id file not found: $MACHINE_ID_FILE" >&2
  exit 1
fi

MACHINE_ID=$(tr -d '\n' < "$MACHINE_ID_FILE" | tr -d '-')
if [ -z "$MACHINE_ID" ]; then
  echo "machine-id is empty" >&2
  exit 1
fi

HOST_SUFFIX=${MACHINE_ID:0:6}
HOSTNAME="${PREFIX}-${HOST_SUFFIX}"

# If hostname is already set to the derived value, do nothing.
CURRENT_HOSTNAME=$(hostname -s 2>/dev/null || true)
if [ "$CURRENT_HOSTNAME" = "$HOSTNAME" ]; then
  echo "Hostname already set to $HOSTNAME"
  exit 0
fi

hostnamectl set-hostname "$HOSTNAME"
echo "Derived hostname: $HOSTNAME"
