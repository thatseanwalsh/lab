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

set -euo pipefail

REPO_DIR="/opt/gitops/repo"
REPO_URL="${GITOPS_REPO_URL:-https://github.com/thatseanwalsh/lab.git}"
BRANCH="${GITOPS_BRANCH:-main}"
QUADLET_DST="/etc/containers/systemd"
SECRETS_DST="/run/secrets"
AGE_KEY="/run/age.key"
LOG_TAG="gitops-sync"
HOSTNAME=""
CORE_SESSION_READY=false

log() { logger -t "$LOG_TAG" "$*"; echo "$(date -Iseconds) [sync] $*"; }
warn() { logger -p user.warning -t "$LOG_TAG" "WARN: $*"; echo "$(date -Iseconds) [sync] WARN: $*"; }
git_exec() { git -C "$REPO_DIR" "$@"; }

install_if_changed() {
  local src="$1" dst="$2" mode="${3:-644}"
  mkdir -p "$(dirname "$dst")"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -m "$mode" "$src" "$dst"
    echo "changed"
  fi
  return 0
}

load_host_settings() {
  if [ -f /etc/gitops.env ]; then
    source /etc/gitops.env
  fi
  HOSTNAME="${GITOPS_HOSTNAME:-$(hostname -s)}"
  log "Hostname: $HOSTNAME"
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
    warn "/run/user/1000 not present — is lingering enabled for core?"
  fi
}

ensure_repo() {
  if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning $REPO_URL (branch: $BRANCH)..."
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    return
  fi

  # Verify repo integrity before doing anything
  if ! git -C "$REPO_DIR" fsck --no-progress --connectivity-only &>/dev/null; then
    warn "Repo integrity check failed — nuking and re-cloning"
    rm -rf "$REPO_DIR"
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    return
  fi

  BEFORE=$(git_exec rev-parse HEAD)
  if ! git_exec fetch --depth=1 origin "$BRANCH" 2>&1 | logger -t "$LOG_TAG"; then
    warn "Fetch failed — nuking and re-cloning"
    rm -rf "$REPO_DIR"
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    return
  fi
  git_exec reset --hard "origin/$BRANCH"
  AFTER=$(git_exec rev-parse HEAD)
  [ "$BEFORE" = "$AFTER" ] \
    && log "Repo unchanged at $BEFORE" \
    || log "Repo updated: $BEFORE → $AFTER"
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
      *.key.enc)
        SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt --input-type binary --output-type binary "$enc_file" > "$tmp" 2>/dev/null
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
    fi
  done
  shopt -u nullglob
}

sync_rootless_secrets() {
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless secrets sync — core session not ready"; return 0; }

  local dst="/run/user/1000/secrets"
  mkdir -p "$dst"
  chown core:core "$dst"
  chmod 700 "$dst"

  shopt -s nullglob
  for src in "$SECRETS_DST"/*; do
    [ -f "$src" ] || continue
    local base dst_file
    base=$(basename "$src")
    dst_file="$dst/$base"
    if ! cmp -s "$src" "$dst_file" 2>/dev/null; then
      cp "$src" "$dst_file"
      chown core:core "$dst_file"
      chmod 600 "$dst_file"
      log "Copied secret for rootless use: $base"
    fi
  done
  shopt -u nullglob
}

# ── Quadlet sync helpers ───────────────────────────────────────────────────

sync_quadlet_dir() {
  # Syncs all quadlet files from a source dir to a destination dir
  local src_dir="$1" dst_dir="$2" changed_array="$3" owner="${4:-root}"
  [ -d "$src_dir" ] || return 0

  shopt -s nullglob
  for ext in container network volume pod kube image; do
    for src in "$src_dir"/*."$ext"; do
      [ -f "$src" ] || continue
      local dst="$dst_dir/$(basename "$src")"
      if [ "$owner" = "core" ]; then
        if ! cmp -s "$src" "$dst" 2>/dev/null; then
          install -o core -g core -m 644 "$src" "$dst"
          eval "${changed_array}+=(\"$(basename "$src")\")"
          log "Updated quadlet (rootless): $(basename "$src")"
        fi
      else
        if [ "$(install_if_changed "$src" "$dst" 644)" = "changed" ]; then
          eval "${changed_array}+=(\"$(basename "$src")\")"
          log "Updated quadlet: $(basename "$src")"
        fi
      fi
    done
  done
  shopt -u nullglob
}

sync_quadlets() {
  CHANGED_UNITS=()
  mkdir -p "$QUADLET_DST"

  # All-host root quadlets
  sync_quadlet_dir "$REPO_DIR/quadlets" "$QUADLET_DST" "CHANGED_UNITS" "root"

  # Host-specific root quadlets
  sync_quadlet_dir "$REPO_DIR/quadlets/$HOSTNAME" "$QUADLET_DST" "CHANGED_UNITS" "root"

  # Remove stale quadlets
  shopt -s nullglob
  for dst in "$QUADLET_DST"/*.{container,network,volume,pod,kube,image}; do
    [ -f "$dst" ] || continue
    local base
    base=$(basename "$dst")
    if [ ! -f "$REPO_DIR/quadlets/$base" ] && [ ! -f "$REPO_DIR/quadlets/$HOSTNAME/$base" ]; then
      local svc="${base%.*}"
      log "Removing stale quadlet: $base"
      systemctl stop "$svc" 2>/dev/null || true
      rm -f "$dst"
      CHANGED_UNITS+=("$base")
    fi
  done
  shopt -u nullglob
}

sync_rootless_quadlets() {
  ROOTLESS_CHANGED=()
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless quadlet sync — core session not ready"; return 0; }

  local dst="/home/core/.config/containers/systemd"
  mkdir -p "$dst"
  chown core:core "$dst" -R || true

  # All-host rootless quadlets
  sync_quadlet_dir "$REPO_DIR/quadlets-rootless" "$dst" "ROOTLESS_CHANGED" "core"

  # Host-specific rootless quadlets
  sync_quadlet_dir "$REPO_DIR/quadlets-rootless/$HOSTNAME" "$dst" "ROOTLESS_CHANGED" "core"

  # Remove stale quadlets
  shopt -s nullglob
  for f in "$dst"/*.{container,network,volume,pod,kube,image}; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f")
    if [ ! -f "$REPO_DIR/quadlets-rootless/$base" ] && [ ! -f "$REPO_DIR/quadlets-rootless/$HOSTNAME/$base" ]; then
      local svc="${base%.*}"
      log "Removing stale rootless quadlet: $base"
      systemd-run --user --machine=core@ systemctl --user stop "$svc" 2>/dev/null || true
      rm -f "$f"
      ROOTLESS_CHANGED+=("$base")
    fi
  done
  shopt -u nullglob
}

# ── Config sync ────────────────────────────────────────────────────────────

sync_configs() {
  # Load all secrets into env for envsubst
  shopt -s nullglob
  for env_file in "$SECRETS_DST"/*.env; do
    source "$env_file"
  done

  for env_file in "/run/user/1000/secrets"/*.env; do
    source "$env_file"
  done
  
  _deploy_config() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    local tmp
    tmp=$(mktemp)
    envsubst < "$src" > "$tmp"
    if ! cmp -s "$tmp" "$dst" 2>/dev/null; then
      install -m 644 "$tmp" "$dst"
      chcon -t container_file_t "$dst" 2>/dev/null || true
      log "Updated config: $dst"
    fi
    rm -f "$tmp"
  }

  # All-host configs
  for app_dir in "$REPO_DIR"/configs/*/; do
    local app
    app=$(basename "$app_dir")
    [ "$app" = "$HOSTNAME" ] && continue
    for src in "$app_dir"*; do
      [ -f "$src" ] || continue
      _deploy_config "$src" "/etc/$app/$(basename "$src")"
    done
  done

  # Host-specific config overrides
  if [ -d "$REPO_DIR/configs/$HOSTNAME" ]; then
    for app_dir in "$REPO_DIR/configs/$HOSTNAME"/*/; do
      local app
      app=$(basename "$app_dir")
      for src in "$app_dir"*; do
        [ -f "$src" ] || continue
        _deploy_config "$src" "/etc/$app/$(basename "$src")"
      done
    done
  fi

  shopt -u nullglob
}

sync_rootless_caddy() {
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless Caddyfile sync — core session not ready"; return 0; }

  local src="$REPO_DIR/caddy/Caddyfile"
  [ -f "$src" ] || return 0

  local dst="/home/core/caddy/Caddyfile"
  mkdir -p "$(dirname "$dst")"
  chown core:core "$(dirname "$dst")" || true

  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -o core -g core -m 644 "$src" "$dst"
    log "Updated rootless Caddyfile"

    if sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active caddy-proxy.service &>/dev/null; then
      # validate — ignore warnings, only fail on error level messages
      local validate_output
      validate_output=$(sudo -u core XDG_RUNTIME_DIR=/run/user/1000 \
        podman exec systemd-caddy-proxy caddy validate --config /etc/caddy/Caddyfile 2>&1)
      if echo "$validate_output" | grep -q '"level":"error"'; then
        warn "Caddyfile has errors — not reloading"
        warn "$validate_output"
      else
        sudo -u core XDG_RUNTIME_DIR=/run/user/1000 \
          systemctl --user restart caddy-proxy.service 2>/dev/null \
          && log "Caddy reloaded gracefully" \
          || warn "Caddy reload failed"
      fi
    else
      warn "caddy-proxy not active — not reloading"
    fi
  fi
}

sync_sops_config() {
  [ -f "$REPO_DIR/.sops.yaml" ] || return 0
  if [ "$(install_if_changed "$REPO_DIR/.sops.yaml" /etc/sops/.sops.yaml 644)" = "changed" ]; then
    log "Updated /etc/sops/.sops.yaml"
  fi
}

# ── Unit reload ────────────────────────────────────────────────────────────

reload_units() {
  [ ${#CHANGED_UNITS[@]} -gt 0 ] || return 0
  log "systemctl daemon-reload (${#CHANGED_UNITS[@]} changed)"
  systemctl daemon-reload
  for unit in "${CHANGED_UNITS[@]}"; do
    local svc="${unit%.*}"
    systemctl restart "$svc" 2>/dev/null \
      && log "Restarted $svc" \
      || warn "$svc restart failed — journalctl -u $svc"
  done
}

reload_rootless_units() {
  [ ${#ROOTLESS_CHANGED[@]} -gt 0 ] || return 0
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless unit reload — core session not ready"; return 0; }

  log "Reloading rootless units (${#ROOTLESS_CHANGED[@]} changed)"
  sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
  for unit in "${ROOTLESS_CHANGED[@]}"; do
    local svc="${unit%.*}"
    sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart "$svc" \
      && log "Restarted (rootless) $svc" \
      || warn "(rootless) $svc restart failed"
  done
}

# ── Secret-dependent container restarts ────────────────────────────────────

restart_secret_containers() {
  [ ${#SECRETS_CHANGED[@]} -eq 0 ] && return 0
  log "Changed secrets: ${SECRETS_CHANGED[*]}"
  shopt -s nullglob
  for unit_file in "$QUADLET_DST"/*.container; do
    [ -f "$unit_file" ] || continue
    local svc label
    svc="$(basename "$unit_file" .container)"
    label=$(grep -i '^Label=secrets=' "$unit_file" | sed 's/^[Ll]abel=secrets=//' | tr ',' '\n') 2>/dev/null || true
    [ -z "$label" ] && continue
    for changed in "${SECRETS_CHANGED[@]}"; do
      if echo "$label" | grep -qxF "$changed"; then
        systemctl restart "$svc" 2>/dev/null \
          && log "Restarted $svc (secret: $changed)" \
          || warn "$svc restart failed"
        break
      fi
    done
  done
  shopt -u nullglob
}

restart_rootless_secret_containers() {
  [ ${#SECRETS_CHANGED[@]} -eq 0 ] && return 0
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless secret-container restart — core session not ready"; return 0; }

  log "Changed secrets: ${SECRETS_CHANGED[*]}"
  local quadlet_dir="/home/core/.config/containers/systemd"
  shopt -s nullglob
  for unit_file in "$quadlet_dir"/*.container; do
    [ -f "$unit_file" ] || continue
    local svc label
    svc="$(basename "$unit_file" .container)"
    label=$(grep -i '^Label=secrets=' "$unit_file" | sed 's/^[Ll]abel=secrets=//' | tr ',' '\n') 2>/dev/null || true
    [ -z "$label" ] && continue
    for changed in "${SECRETS_CHANGED[@]}"; do
      if echo "$label" | grep -qxF "$changed"; then
        sudo -u core XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart "$svc" 2>/dev/null \
          && log "Restarted (rootless) $svc (secret: $changed)" \
          || warn "(rootless) $svc restart failed"
        break
      fi
    done
  done
  shopt -u nullglob
}

# ── GHCR login ─────────────────────────────────────────────────────────────

podman_login_ghcr() {
  local ghcr_env="$SECRETS_DST/ghcr.env"
  [ -f "$ghcr_env" ] || { warn "GHCR credentials not found, skipping podman login"; return 0; }
  source "$ghcr_env"
  [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] || return 0

  local tries=0
  while [ $tries -lt 5 ]; do
    if echo "$GHCR_TOKEN" | podman login ghcr.io -u "$GHCR_USERNAME" --password-stdin 2>/dev/null; then
      log "Logged in to ghcr.io as $GHCR_USERNAME"
      return 0
    fi
    tries=$((tries + 1))
    warn "GHCR login attempt $tries failed, retrying in 5s..."
    sleep 5
  done
  warn "podman login to ghcr.io failed after $tries attempts — continuing anyway"
  return 0
}

podman_login_ghcr_rootless() {
  local ghcr_env="$SECRETS_DST/ghcr.env"
  [ -f "$ghcr_env" ] || return 0
  source "$ghcr_env"
  [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] || return 0
  [ "$CORE_SESSION_READY" = true ] || { warn "Skipping rootless GHCR login — core session not ready"; return 0; }

  local tries=0
  while [ $tries -lt 5 ]; do
    if echo "$GHCR_TOKEN" | sudo -u core \
        XDG_RUNTIME_DIR=/run/user/1000 \
        HOME=/home/core \
        /usr/bin/podman login ghcr.io -u "$GHCR_USERNAME" --password-stdin 2>/dev/null; then
      log "Logged in to ghcr.io as $GHCR_USERNAME (rootless)"
      return 0
    fi
    tries=$((tries + 1))
    warn "Rootless GHCR login attempt $tries failed, retrying in 5s..."
    sleep 5
  done
  warn "podman login to ghcr.io (rootless) failed after $tries attempts — continuing anyway"
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
  ensure_age_key
  ensure_repo

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
    log "Skipping secret decryption — age key unavailable"
    SECRETS_CHANGED=()
  fi

  sync_quadlets
  sync_rootless_quadlets
  sync_configs
  sync_sops_config
  sync_rootless_caddy
  reload_units
  reload_rootless_units
  restart_secret_containers
  restart_rootless_secret_containers
  log "Sync complete."
}

main