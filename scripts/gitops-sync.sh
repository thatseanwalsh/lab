#!/bin/bash
# /opt/gitops/sync.sh
#
# GitOps sync — runs every 5 minutes via systemd timer.
#
# Prerequisites satisfied by systemd before this runs:
#   - tpm-unseal-age.service has placed /run/age.key (mode 0400)
#   - network-online.target is reached
#   - sops is installed at /usr/local/bin/sops
#
# This script:
#   1. clones or updates the repo
#   2. decrypts secrets/*.enc → /run/secrets/
#   3. syncs quadlets → /etc/containers/systemd/
#   4. syncs .sops.yaml → /etc/sops/.sops.yaml
#   5. syncs Caddyfile → /etc/caddy/Caddyfile
#   6. syncs firewalld/*.xml → /etc/firewalld/zones/
#   7. reloads changed units and secret-dependent containers

set -euo pipefail

REPO_DIR="/opt/gitops/repo"
REPO_URL="${GITOPS_REPO_URL:-https://github.com/thatseanwalsh/lab.git}"
BRANCH="${GITOPS_BRANCH:-main}"
QUADLET_DST="/etc/containers/systemd"
CADDY_DST="/etc/caddy"
FIREWALLD_DST="/etc/firewalld/zones"
SECRETS_DST="/run/secrets"
AGE_KEY="/run/age.key"
LOG_TAG="gitops-sync"
HOSTNAME=""
HOST_QUADLET_DIR=""

log() { logger -t "$LOG_TAG" "$*"; echo "$(date -Iseconds) [sync] $*"; }
warn() { logger -p user.warning -t "$LOG_TAG" "WARN: $*"; echo "$(date -Iseconds) [sync] WARN: $*"; }

git_exec() { git -C "$REPO_DIR" "$@"; }

load_host_settings() {
  if [ -f /etc/gitops.env ]; then
    # shellcheck source=/dev/null
    source /etc/gitops.env
  fi
  HOSTNAME="${GITOPS_HOSTNAME:-$(hostname -s)}"
  HOST_QUADLET_DIR="$REPO_DIR/quadlets/$HOSTNAME"
  log "Host-specific quadlets directory: $HOST_QUADLET_DIR"
}

ensure_age_key() {
  if [ -f "$AGE_KEY" ]; then
    log "Age key available at $AGE_KEY"
    AGE_KEY_AVAILABLE=true
  else
    warn "Age key not found at $AGE_KEY"
    warn "Check: systemctl status tpm-unseal-age.service"
    warn "Check: journalctl -u coreos-tpm-enroll"
    warn "Secrets will not be decrypted this cycle."
    AGE_KEY_AVAILABLE=false
  fi
}

ensure_repo() {
  if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning $REPO_URL (branch: $BRANCH)..."
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  else
    BEFORE=$(git_exec rev-parse HEAD)
    git_exec fetch --depth=1 origin "$BRANCH" 2>&1 | logger -t "$LOG_TAG"
    git_exec reset --hard "origin/$BRANCH"
    AFTER=$(git_exec rev-parse HEAD)
    if [ "$BEFORE" = "$AFTER" ]; then
      log "Repo unchanged at $BEFORE — re-checking secrets freshness"
    else
      log "Repo updated: $BEFORE → $AFTER"
    fi
  fi
}

install_if_changed() {
  local src="$1" dst="$2" mode="${3:-644}"
  mkdir -p "$(dirname "$dst")"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -m "$mode" "$src" "$dst"
    return 0
  fi
  return 1
}

decrypt_secrets() {
  SECRETS_CHANGED=()
  mkdir -p "$SECRETS_DST"
  chmod 700 "$SECRETS_DST"

  shopt -s nullglob
  for enc_file in "$REPO_DIR"/secrets/*.enc; do
    [ -f "$enc_file" ] || continue

    base=$(basename "$enc_file" .enc)
    dest="$SECRETS_DST/$base"
    tmp=$(mktemp "$SECRETS_DST/.tmp.XXXXXX")
    chmod 600 "$tmp"

    if SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt "$enc_file" > "$tmp" 2>/dev/null; then
      if ! cmp -s "$tmp" "$dest" 2>/dev/null; then
        mv "$tmp" "$dest"
        chmod 600 "$dest"
        SECRETS_CHANGED+=("$base")
        log "Decrypted: $enc_file → $dest"
      else
        rm -f "$tmp"
      fi
    else
      rm -f "$tmp"
      warn "Decryption failed: $enc_file"
      warn "Ensure the host age public key is present in .sops.yaml and the file is valid."
    fi
  done
  shopt -u nullglob
}

sync_quadlets() {
  CHANGED_UNITS=()
  mkdir -p "$QUADLET_DST"

  shopt -s nullglob
  for ext in container network volume pod kube image; do
    for src in "$REPO_DIR"/quadlets/*."$ext"; do
      [ -f "$src" ] || continue
      dst="$QUADLET_DST/$(basename "$src")"
      if install_if_changed "$src" "$dst" 644; then
        CHANGED_UNITS+=("$(basename "$src")")
        log "Updated quadlet: $(basename "$src")"
      fi
    done
  done

  for dst in "$QUADLET_DST"/*.{container,network,volume,pod,kube,image}; do
    [ -f "$dst" ] || continue
    if [ ! -f "$REPO_DIR/quadlets/$(basename "$dst")" ] && [ ! -f "$HOST_QUADLET_DIR/$(basename "$dst")" ]; then
      svc="${dst##*/}"
      svc="${svc%.*}"
      log "Removing stale quadlet: $(basename "$dst")"
      systemctl stop "$svc" 2>/dev/null || true
      rm -f "$dst"
      CHANGED_UNITS+=("$(basename "$dst")")
    fi
  done
  shopt -u nullglob
}

sync_host_quadlets() {
  if [ ! -d "$HOST_QUADLET_DIR" ]; then
    log "No host-specific quadlets for $HOSTNAME"
    return
  fi

  shopt -s nullglob
  for ext in container network volume pod kube image; do
    for src in "$HOST_QUADLET_DIR"/*."$ext"; do
      [ -f "$src" ] || continue
      dst="$QUADLET_DST/$(basename "$src")"
      if install_if_changed "$src" "$dst" 644; then
        CHANGED_UNITS+=("$(basename "$src")")
        log "Updated host quadlet: $(basename "$src")"
      fi
    done
  done
  shopt -u nullglob
}

sync_sops_config() {
  if [ -f "$REPO_DIR/.sops.yaml" ]; then
    if install_if_changed "$REPO_DIR/.sops.yaml" /etc/sops/.sops.yaml 644; then
      log "Updated /etc/sops/.sops.yaml"
    fi
  fi
}

sync_caddy() {
  if [ -f "$REPO_DIR/caddy/Caddyfile" ]; then
    mkdir -p "$CADDY_DST"
    if install_if_changed "$REPO_DIR/caddy/Caddyfile" "$CADDY_DST/Caddyfile" 640; then
      log "Updated Caddyfile"
      if systemctl is-active caddy-proxy.service &>/dev/null && podman exec caddy-proxy caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
        systemctl reload caddy-proxy.service 2>/dev/null && log "Caddy reloaded (graceful)" || warn "Caddy reload failed"
      else
        warn "Caddyfile validation failed or caddy-proxy unavailable — not reloading"
      fi
    fi
  fi
}

sync_firewalld() {
  if compgen -G "$REPO_DIR/firewalld/*.xml" > /dev/null 2>&1; then
    mkdir -p "$FIREWALLD_DST"
    FW_CHANGED=false
    shopt -s nullglob
    for src in "$REPO_DIR"/firewalld/*.xml; do
      [ -f "$src" ] || continue
      dest="$FIREWALLD_DST/$(basename "$src")"
      if install_if_changed "$src" "$dest" 644; then
        log "Updated firewalld zone: $(basename "$src")"
        FW_CHANGED=true
      fi
    done
    shopt -u nullglob
    if [ "$FW_CHANGED" = true ] && systemctl is-active firewalld.service &>/dev/null; then
      firewall-cmd --reload && log "firewalld reloaded" || warn "firewalld reload failed"
    fi
  fi
}

reload_units() {
  if [ ${#CHANGED_UNITS[@]} -gt 0 ]; then
    log "systemctl daemon-reload (${#CHANGED_UNITS[@]} changed)"
    systemctl daemon-reload
    for unit in "${CHANGED_UNITS[@]}"; do
      svc="${unit%.*}"
      systemctl restart "$svc" 2>/dev/null && log "Restarted $svc" || warn "$svc restart failed — journalctl -u $svc"
    done
  fi
}

restart_secret_containers() {
  if [ ${#SECRETS_CHANGED[@]} -eq 0 ]; then
    return
  fi
  log "Changed secrets: ${SECRETS_CHANGED[*]}"
  shopt -s nullglob
  for unit_file in "$QUADLET_DST"/*.container; do
    [ -f "$unit_file" ] || continue
    svc="$(basename "$unit_file" .container)"
    label=$(grep -i '^Label=secrets=' "$unit_file" | sed 's/^[Ll]abel=secrets=//' | tr ',' '\n') 2>/dev/null || true
    [ -z "$label" ] && continue
    for changed in "${SECRETS_CHANGED[@]}"; do
      if echo "$label" | grep -qxF "$changed"; then
        systemctl restart "$svc" 2>/dev/null && log "Restarted $svc (secret: $changed changed)" || warn "$svc restart failed"
        break
      fi
    done
  done
  shopt -u nullglob
}

main() {
  ensure_age_key
  ensure_repo
  load_host_settings
  if [ "$AGE_KEY_AVAILABLE" = true ]; then
    decrypt_secrets
  else
    log "Skipping secret decryption because age key is unavailable"
    SECRETS_CHANGED=()
  fi
  sync_quadlets
  sync_host_quadlets
  sync_sops_config
  sync_caddy
  sync_firewalld
  reload_units
  restart_secret_containers
  log "Sync complete."
}

main
