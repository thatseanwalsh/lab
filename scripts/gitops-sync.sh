#!/bin/bash
# /opt/gitops/sync.sh
#
# GitOps sync — runs every 5 minutes via systemd timer.
#
# Prerequisites satisfied by systemd before this runs:
#   - tpm-unseal-age.service has placed /run/age.key (mode 0400)
#   - network-online.target is reached
#   - sops is installed at /usr/local/bin/sops
#   - enable-linger.service has run (core's user session may still be starting)
#
# This script:
#   1. clones or updates the repo
#   2. decrypts secrets/*.enc → /run/secrets/
#   3. syncs root quadlets → /etc/containers/systemd/
#   4. syncs rootless quadlets → /home/core/.config/containers/systemd/
#   5. syncs .sops.yaml → /etc/sops/.sops.yaml
#   6. syncs Caddyfile → /etc/caddy/Caddyfile
#   7. syncs itself → /opt/gitops/sync.sh
#   8. reloads changed units and secret-dependent containers (root + rootless)

set -euo pipefail

REPO_DIR="/opt/gitops/repo"
REPO_URL="${GITOPS_REPO_URL:-https://github.com/thatseanwalsh/lab.git}"
BRANCH="${GITOPS_BRANCH:-main}"
QUADLET_DST="/etc/containers/systemd"
CADDY_DST="/etc/caddy"
SECRETS_DST="/run/secrets"
AGE_KEY="/run/age.key"
LOG_TAG="gitops-sync"
HOSTNAME=""
HOST_QUADLET_DIR=""
HOST_QUADLET_DIR_ROOTLESS=""
CORE_SESSION_READY=false

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
  HOST_QUADLET_DIR_ROOTLESS="$REPO_DIR/quadlets-rootless/$HOSTNAME"
  log "Host-specific quadlets directory: $HOST_QUADLET_DIR"
  log "Host-specific rootless quadlets directory: $HOST_QUADLET_DIR_ROOTLESS"
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

# Waits (once per sync cycle) for core's user session / runtime dir to be up.
# Rootless functions check $CORE_SESSION_READY instead of waiting individually.
wait_for_core_session() {
  local tries=0
  while [ ! -d "/run/user/1000" ] && [ "$tries" -lt 10 ]; do
    sleep 1
    tries=$((tries + 1))
  done

  if [ -d "/run/user/1000" ]; then
    CORE_SESSION_READY=true
  else
    CORE_SESSION_READY=false
    warn "/run/user/1000 still not present after waiting — is lingering enabled for core?"
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

    case "$enc_file" in
      *.env.enc|*.env)
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt --input-type dotenv --output-type dotenv "$enc_file" > "$tmp" 2>/dev/null
        decrypt_status=$?
        ;;
      *)
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt "$enc_file" > "$tmp" 2>/dev/null
        decrypt_status=$?
        ;;
    esac

    if [ "$decrypt_status" -eq 0 ]; then
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

sync_rootless_secrets() {
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless secrets sync — core session not ready"; return; }

  local rootless_secrets_dst="/run/user/1000/secrets"
  mkdir -p "$rootless_secrets_dst"
  chown core:core "$rootless_secrets_dst"
  chmod 700 "$rootless_secrets_dst"

  shopt -s nullglob
  for src in "$SECRETS_DST"/*; do
    [ -f "$src" ] || continue
    base=$(basename "$src")
    dst="$rootless_secrets_dst/$base"

    if ! cmp -s "$src" "$dst" 2>/dev/null; then
      cp "$src" "$dst"
      chown core:core "$dst"
      chmod 600 "$dst"
      log "Copied secret for rootless use: $base"
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

sync_rootless_quadlets() {
  ROOTLESS_CHANGED=()
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless quadlet sync — core session not ready"; return; }

  local dst="/home/core/.config/containers/systemd"
  mkdir -p "$dst"
  chown core:core "$dst" -R

  shopt -s nullglob
  for ext in container network volume pod kube image; do
    for src in "$REPO_DIR"/quadlets-rootless/*."$ext"; do
      [ -f "$src" ] || continue
      target="$dst/$(basename "$src")"
      if ! cmp -s "$src" "$target" 2>/dev/null; then
        install -o core -g core -m 644 "$src" "$target"
        ROOTLESS_CHANGED+=("$(basename "$src")")
        log "Updated rootless quadlet: $(basename "$src")"
      fi
    done
  done
  shopt -u nullglob
}

sync_rootless_host_quadlets() {
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless host quadlet sync — core session not ready"; return; }

  local host_dir="$HOST_QUADLET_DIR_ROOTLESS"
  local dst="/home/core/.config/containers/systemd"

  if [ ! -d "$host_dir" ]; then
    log "No host-specific rootless quadlets for $HOSTNAME"
    return
  fi

  mkdir -p "$dst"
  chown core:core "$dst"

  shopt -s nullglob
  for ext in container network volume pod kube image; do
    for src in "$host_dir"/*."$ext"; do
      [ -f "$src" ] || continue
      target="$dst/$(basename "$src")"
      if ! cmp -s "$src" "$target" 2>/dev/null; then
        install -o core -g core -m 644 "$src" "$target"
        ROOTLESS_CHANGED+=("$(basename "$src")")
        log "Updated host rootless quadlet: $(basename "$src")"
      fi
    done
  done
  shopt -u nullglob
}

reload_rootless_units() {
  [ ${#ROOTLESS_CHANGED[@]} -gt 0 ] || return
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless unit reload — core session not ready"; return; }

  log "Reloading rootless units for core (${#ROOTLESS_CHANGED[@]} changed)"
  sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
  for unit in "${ROOTLESS_CHANGED[@]}"; do
    svc="${unit%.*}"
    sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart "$svc" \
      && log "Restarted (rootless) $svc" \
      || warn "(rootless) $svc restart failed"
  done
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

sync_rootless_caddy() {
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless Caddyfile sync — core session not ready"; return; }

  if [ -f "$REPO_DIR/caddy/Caddyfile" ]; then
    local dst="/home/core/caddy/Caddyfile"
    mkdir -p "$(dirname "$dst")"
    chown core:core "$(dirname "$dst")"

    if ! cmp -s "$REPO_DIR/caddy/Caddyfile" "$dst" 2>/dev/null; then
      install -o core -g core -m 644 "$REPO_DIR/caddy/Caddyfile" "$dst"
      log "Updated rootless Caddyfile"

      if sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active caddy-proxy.service &>/dev/null \
         && sudo -u core XDG_RUNTIME_DIR=/run/user/1000 podman exec caddy-proxy caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
        sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user reload caddy-proxy.service 2>/dev/null \
          && log "Caddy (rootless) reloaded gracefully" \
          || warn "Caddy (rootless) reload failed"
      else
        warn "Rootless Caddyfile validation failed or caddy-proxy unavailable — not reloading"
      fi
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

restart_rootless_secret_containers() {
  if [ ${#SECRETS_CHANGED[@]} -eq 0 ]; then
    return
  fi
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless secret-container restart — core session not ready"; return; }

  log "Changed secrets: ${SECRETS_CHANGED[*]}"
  local dst="/home/core/.config/containers/systemd"
  shopt -s nullglob
  for unit_file in "$dst"/*.container; do
    [ -f "$unit_file" ] || continue
    svc="$(basename "$unit_file" .container)"
    label=$(grep -i '^Label=secrets=' "$unit_file" | sed 's/^[Ll]abel=secrets=//' | tr ',' '\n') 2>/dev/null || true
    [ -z "$label" ] && continue
    for changed in "${SECRETS_CHANGED[@]}"; do
      if echo "$label" | grep -qxF "$changed"; then
        sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart "$svc" 2>/dev/null \
          && log "Restarted (rootless) $svc (secret: $changed changed)" \
          || warn "(rootless) $svc restart failed"
        break
      fi
    done
  done
  shopt -u nullglob
}

podman_login_ghcr() {
  local ghcr_env="$SECRETS_DST/ghcr.env"
  [ -f "$ghcr_env" ] || { warn "GHCR credentials not found, skipping podman login"; return; }

  # shellcheck disable=SC1090
  source "$ghcr_env"

  if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    if echo "$GHCR_TOKEN" | podman login ghcr.io -u "$GHCR_USERNAME" --password-stdin 2>/dev/null; then
      log "Logged in to ghcr.io as $GHCR_USERNAME"
    else
      warn "podman login to ghcr.io failed"
    fi
  fi
}

podman_login_ghcr_rootless() {
  local ghcr_env="$SECRETS_DST/ghcr.env"
  [ -f "$ghcr_env" ] || return
  source "$ghcr_env"
  [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] || return

  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless GHCR login — core session not ready"; return; }

  echo "$GHCR_TOKEN" | sudo -u core XDG_RUNTIME_DIR=/run/user/1000 \
    podman login ghcr.io -u "$GHCR_USERNAME" --password-stdin 2>/dev/null \
    && log "Logged in to ghcr.io as $GHCR_USERNAME (rootless)" \
    || warn "podman login to ghcr.io (rootless) failed"
}

main() {
  ensure_age_key
  ensure_repo

  # Sync the sync script
  if ! cmp -s "$REPO_DIR/scripts/gitops-sync.sh" "$0"; then
    log "sync.sh changed in repo, updating and re-executing..."
    cp "$REPO_DIR/scripts/gitops-sync.sh" "$0"
    chmod 750 "$0"
    exec "$0" "$@"
  fi

  load_host_settings
  wait_for_core_session

  if [ "$AGE_KEY_AVAILABLE" = true ]; then
    decrypt_secrets
    sync_rootless_secrets
    podman_login_ghcr
    podman_login_ghcr_rootless
  else
    log "Skipping secret decryption because age key is unavailable"
    SECRETS_CHANGED=()
  fi

  sync_quadlets
  sync_rootless_quadlets
  sync_host_quadlets
  sync_rootless_host_quadlets
  sync_sops_config
  sync_rootless_caddy
  reload_units
  reload_rootless_units
  restart_secret_containers
  restart_rootless_secret_containers
  log "Sync complete."
}

main