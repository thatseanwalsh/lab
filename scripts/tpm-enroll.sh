#!/bin/bash
# /usr/local/bin/tpm-enroll.sh
#
# Phase 1: LUKS  — bind root drive to TPM2 PCRs + enroll recovery key
# Phase 2: age   — derive age keypair from TPM2 seed, seal with systemd-creds
#
# Runs ONCE on first boot (sentinel-gated: ConditionPathExists=!/var/lib/.tpm-enrolled).
#
# After this runs:
#   - LUKS auto-unlocks via TPM2 on every subsequent boot
#   - /etc/age/age.identity.secure exists (systemd-creds encrypted blob)
#   - tpm-unseal-age.service decrypts it to /run/age.key on every boot
#   - gitops-sync reads /run/age.key directly — no Clevis, no manual unsealing
#
# The age PUBLIC KEY is printed to the journal. Capture it once:
#   journalctl -u coreos-tpm-enroll | grep AGE_PUBLIC_KEY
# Then add it to .sops.yaml in git and push.
#
# PCRs bound for LUKS: 0 (UEFI firmware), 7 (Secure Boot), 8 (GRUB), 9 (cmdline)
# systemd-creds uses its own PCR policy internally (PCR 11 + Secure Boot state)

set -euo pipefail

SENTINEL="/var/lib/.tpm-enrolled"
AGE_CREDS_DIR="/etc/age"
AGE_CREDS_FILE="$AGE_CREDS_DIR/age.identity.secure"
TPM_CTX_DIR="$(mktemp -d /tmp/tpm-enroll-XXXXXX)"
PCR_POLICY='{"pcr_bank":"sha256","pcr_ids":"0,7,8,9"}'
LOG_TAG="tpm-enroll"

log() { logger -t "$LOG_TAG" "$*"; echo "[tpm-enroll] $*"; }
die() { log "ERROR: $*"; exit 1; }
cleanup() { rm -rf "$TPM_CTX_DIR"; }
trap cleanup EXIT

mkdir -p "$AGE_CREDS_DIR"
chmod 700 "$AGE_CREDS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — LUKS binding via Clevis
# ─────────────────────────────────────────────────────────────────────────────

log "=== Phase 1: LUKS TPM2 binding ==="

tpm2_getcap properties-fixed &>/dev/null || die "TPM2 not accessible"
log "TPM2 detected"

LUKS_DEV=""
for dev in /dev/nvme?n? /dev/sd? /dev/vd?; do
  [ -b "$dev" ] || continue
  cryptsetup isLuks "$dev" 2>/dev/null && { LUKS_DEV="$dev"; break; }
done
[ -n "$LUKS_DEV" ] || die "No LUKS device found"
log "LUKS device: $LUKS_DEV"

LUKS_KEYFILE=""
for kf in /etc/luks/*.key /etc/luks/root /etc/luks/key; do
  [ -f "$kf" ] && { LUKS_KEYFILE="$kf"; break; }
done
[ -n "$LUKS_KEYFILE" ] || \
  LUKS_KEYFILE=$(find /etc/luks -type f 2>/dev/null | head -1)
[ -n "$LUKS_KEYFILE" ] || die "LUKS key file not found under /etc/luks/"
log "LUKS key file: $LUKS_KEYFILE"

log "Binding LUKS to TPM2 PCRs 0,7,8,9..."
clevis luks bind -d "$LUKS_DEV" tpm2 "$PCR_POLICY" \
  -- -d "$LUKS_KEYFILE" \
  || die "clevis luks bind failed"
log "LUKS TPM2 binding complete"

# Enroll recovery key into LUKS slot 2
RECOVERY_KEY=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 52)
echo -n "$RECOVERY_KEY" | cryptsetup luksAddKey \
  --key-file "$LUKS_KEYFILE" \
  --key-slot 2 \
  "$LUKS_DEV" \
  || die "Failed to enroll recovery key"

log "========================================================"
log "  LUKS RECOVERY KEY — WRITE THIS DOWN NOW               "
log "  Store offline. Only fallback if TPM2 seal breaks.     "
log "========================================================"
log "  $RECOVERY_KEY"
log "========================================================"
unset RECOVERY_KEY

if command -v dracut &>/dev/null; then
  log "Regenerating initramfs with clevis-tpm2..."
  dracut -f --kver "$(uname -r)" \
    --add "clevis clevis-pin-tpm2 tpm2-tss" \
    || log "WARNING: dracut regeneration failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Derive age keypair from TPM2, seal with systemd-creds
# ─────────────────────────────────────────────────────────────────────────────
#
# Derivation: TPM2 endorsement hierarchy seed → primary key → child HMAC key
# → HMAC("coreos-netbird-age-v1") → 32 deterministic bytes → age Curve25519 keypair
#
# Same chip always produces the same age keypair. Different machines differ.
#
# Sealing: systemd-creds encrypt --with-key=tpm2 binds the age private key
# to this machine's TPM2. At every boot, tpm-unseal-age.service runs:
#   systemd-creds decrypt /etc/age/age.identity.secure /run/age.key
# This is automatic — no manual intervention, no Clevis dependency for age.

log "=== Phase 2: Derive age keypair from TPM2 ==="

PRIMARY_CTX="$TPM_CTX_DIR/primary.ctx"
CHILD_CTX="$TPM_CTX_DIR/child.ctx"
CHILD_PRIV="$TPM_CTX_DIR/child.priv"
CHILD_PUB="$TPM_CTX_DIR/child.pub"
SEED_FILE="$TPM_CTX_DIR/seed.bin"
AGE_KEY_TMP="$TPM_CTX_DIR/age.key"

# 2a. Primary key under Endorsement hierarchy (chip-unique, permanent)
log "Creating TPM2 primary key (endorsement hierarchy)..."
tpm2_createprimary -C e -G ecc256 -c "$PRIMARY_CTX" > /dev/null \
  || die "tpm2_createprimary failed"

# 2b. Deterministic child HMAC key
log "Deriving child HMAC key..."
tpm2_create \
  -C "$PRIMARY_CTX" \
  -G hmac \
  -u "$CHILD_PUB" \
  -r "$CHILD_PRIV" \
  > /dev/null \
  || die "tpm2_create failed"

tpm2_load \
  -C "$PRIMARY_CTX" \
  -u "$CHILD_PUB" \
  -r "$CHILD_PRIV" \
  -c "$CHILD_CTX" \
  > /dev/null \
  || die "tpm2_load failed"

# 2c. 32 deterministic bytes via HMAC over a fixed label
log "Computing HMAC seed..."
printf 'coreos-netbird-age-v1' \
  | tpm2_hmac -c "$CHILD_CTX" -o "$SEED_FILE" /dev/stdin > /dev/null \
  || die "tpm2_hmac failed"

SEED_HEX=$(xxd -p -c 256 "$SEED_FILE" | tr -d '\n')
[ ${#SEED_HEX} -ge 64 ] || die "Seed too short (${#SEED_HEX} hex chars)"
log "TPM2 seed derived"

# 2d. Encode seed as age private key (bech32 AGE-SECRET-KEY-1... format)
AGE_PRIVATE=$(python3 - "$SEED_HEX" << 'PYEOF'
import sys
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; c=1
    for x in v:
        b=c>>25; c=(c&0x1ffffff)<<5^x
        for i in range(5): c^=G[i] if (b>>i)&1 else 0
    return c
def hrp_expand(h): return [ord(x)>>5 for x in h]+[0]+[ord(x)&31 for x in h]
def encode(hrp,data):
    d=data+[0]*6; p=polymod(hrp_expand(hrp)+d)^1
    ck=[(p>>5*(5-i))&31 for i in range(6)]
    return hrp+'1'+''.join(CHARSET[x] for x in data+ck)
def conv(data,fb,tb,pad=True):
    a=b=0; r=[]; mv=(1<<tb)-1
    for v in data:
        a=((a<<fb)|v)&0xffffffff; b+=fb
        while b>=tb: b-=tb; r.append((a>>b)&mv)
    if pad and b: r.append((a<<(tb-b))&mv)
    return r
s=bytearray(bytes.fromhex(sys.argv[1][:64]))
s[0]&=248; s[31]&=127; s[31]|=64
print(encode("age-secret-key-",conv(list(s),8,5)).upper())
PYEOF
)
[ -n "$AGE_PRIVATE" ] || die "Failed to derive age private key"
log "age private key derived from TPM2 seed"

# 2e. Write temporary key file, derive public key
printf '%s\n' "$AGE_PRIVATE" > "$AGE_KEY_TMP"
chmod 600 "$AGE_KEY_TMP"
AGE_PUBLIC=$(age-keygen -y "$AGE_KEY_TMP" 2>/dev/null) \
  || die "age-keygen -y failed"

log "========================================================"
log "  AGE PUBLIC KEY — ADD TO .sops.yaml IN GIT REPO        "
log "  sops updatekeys secrets/*.enc  →  git push            "
log "========================================================"
log "  AGE_PUBLIC_KEY: $AGE_PUBLIC"
log "========================================================"

# 2f. Seal with systemd-creds
#
# --with-key=tpm2 binds to this machine's TPM2 (uses PCR 11 + host key).
# --pretty writes a human-readable header but the payload is encrypted.
# The output file is safe to store at /etc/age/ (root-only, mode 0600).
#
# At every subsequent boot, tpm-unseal-age.service runs:
#   systemd-creds decrypt /etc/age/age.identity.secure /run/age.key
# which decrypts automatically using the local TPM2 — no passphrase, no Clevis.
log "Sealing age key with systemd-creds (TPM2)..."
printf '%s\n' "$AGE_PRIVATE" \
  | systemd-creds encrypt \
      --with-key=tpm2 \
      --name=age.identity \
      - "$AGE_CREDS_FILE" \
  || die "systemd-creds encrypt failed"
chmod 600 "$AGE_CREDS_FILE"
log "Sealed credential written: $AGE_CREDS_FILE"

# 2g. Clean up — plaintext key must not persist
unset AGE_PRIVATE
unset AGE_PUBLIC
unset SEED_HEX
# AGE_KEY_TMP is in TPM_CTX_DIR, removed by the EXIT trap

log "Plaintext age key cleared from memory and temp dir"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

touch "$SENTINEL"
log "=== TPM2 enrollment complete ==="
log "NEXT STEPS:"
log "  1. journalctl -u coreos-tpm-enroll | grep AGE_PUBLIC_KEY"
log "  2. Add the public key to .sops.yaml in your git repo"
log "  3. sops --encrypt secrets/netbird.env > secrets/netbird.env.enc"
log "  4. git add .sops.yaml secrets/*.enc && git commit && git push"
log "  5. gitops-sync will decrypt secrets on the next cycle (within 5min)"
