#!/usr/bin/env bash
# bento — Phase 0, step 2: configure darwin.linux-builder as the aarch64-linux builder.
#
# Run once:   sudo ./scripts/setup-linux-builder.sh
# Afterwards: ./scripts/start-linux-builder.sh   (no sudo needed, ever again)
#
# Why this exists instead of the stock nixpkgs instructions:
#   1. Determinate Nix OWNS /etc/nix/nix.conf and rewrites it on upgrade. User settings
#      must live in /etc/nix/nix.custom.conf, which nix.conf pulls in via `!include`.
#   2. The nixpkgs docs say to restart `org.nixos.nix-daemon`. On Determinate Nix the
#      launchd label is `systems.determinate.nix-daemon` — the documented command is a
#      silent no-op here.
#   3. We must REMOVE the `external-builders` config we tried first: Determinate's
#      Native Linux Builder is licence-gated (HTTP 400), and while that setting is
#      present it hijacks Linux builds instead of falling through to the remote builder.
#   4. We pre-install the builder SSH keypair ourselves. Upstream's `add-keys` shells out
#      to `sudo` on every launch when /etc/nix/builder_ed25519.pub doesn't match; by
#      installing a stable key here, later launches need no password and the builder VM
#      can be started unattended (e.g. by an agent) in the background.
#
# Idempotent: safe to re-run.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "error: run me with sudo" >&2
  exit 1
fi

BUILDER_USER="${SUDO_USER:-chime}"
USER_HOME=$(eval echo "~${BUILDER_USER}")
STATE_DIR="${USER_HOME}/.local/state/bento"
KEYS_DIR="${STATE_DIR}/builder-keys"
CUSTOM_CONF=/etc/nix/nix.custom.conf
SSH_CONF_DIR=/etc/ssh/ssh_config.d
SSH_CONF="${SSH_CONF_DIR}/100-linux-builder.conf"
DAEMON_LABEL=systems.determinate.nix-daemon

# The builder VM's publicly-known SSH *host* key, base64-encoded, per the nixpkgs manual.
# Safe here: the builder listens on localhost only. Do NOT expose the builder to other
# machines without replacing this.
HOST_KEY_B64='c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo='

echo "==> Ensuring builder keypair in ${KEYS_DIR}"
sudo -u "${BUILDER_USER}" mkdir -p "${KEYS_DIR}"
if [[ ! -e "${KEYS_DIR}/builder_ed25519" || ! -e "${KEYS_DIR}/builder_ed25519.pub" ]]; then
  sudo -u "${BUILDER_USER}" rm -f "${KEYS_DIR}/builder_ed25519" "${KEYS_DIR}/builder_ed25519.pub"
  # Generated AS THE USER on purpose: run-builder reads the private key as the user, so
  # a root-owned 0600 key would make the builder unstartable without sudo.
  sudo -u "${BUILDER_USER}" ssh-keygen -q -f "${KEYS_DIR}/builder_ed25519" \
    -t ed25519 -N "" -C 'builder@localhost'
  echo "    generated a new keypair"
else
  echo "    reusing existing keypair"
fi

echo "==> Installing builder credentials into /etc/nix (what upstream's sudo step does)"
install -g nixbld -m 600 "${KEYS_DIR}/builder_ed25519" /etc/nix/builder_ed25519
install -g nixbld -m 644 "${KEYS_DIR}/builder_ed25519.pub" /etc/nix/builder_ed25519.pub

echo "==> Backing up and rewriting ${CUSTOM_CONF}"
if [[ -f ${CUSTOM_CONF} ]]; then
  cp -p "${CUSTOM_CONF}" "${CUSTOM_CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

# NOTE: POSIX ERE only — macOS ships BSD grep, where \s and \b are not portable.
tmp=$(mktemp)
if [[ -f ${CUSTOM_CONF} ]]; then
  grep -v -E '^[[:space:]]*(external-builders|extra-experimental-features|extra-trusted-users|builders|builders-use-substitutes)[[:space:]]*=' \
    "${CUSTOM_CONF}" \
    | grep -v -F '# --- bento: aarch64-linux remote builder' \
    > "${tmp}" || true
fi

cat >> "${tmp}" <<EOF

# --- bento: aarch64-linux remote builder (darwin.linux-builder) ---
extra-trusted-users = ${BUILDER_USER}
builders = ssh-ng://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 - - - ${HOST_KEY_B64}
builders-use-substitutes = true
EOF

install -m 0644 -o root -g wheel "${tmp}" "${CUSTOM_CONF}"
rm -f "${tmp}"

echo "==> Writing ${SSH_CONF} (the builder listens on 31022, not 22)"
mkdir -p "${SSH_CONF_DIR}"
cat > "${SSH_CONF}" <<'EOF'
Host linux-builder
  Hostname localhost
  HostKeyAlias linux-builder
  Port 31022
  User builder
  IdentityFile /etc/nix/builder_ed25519
EOF
chmod 0644 "${SSH_CONF}"

echo "==> Restarting the Nix daemon (${DAEMON_LABEL})"
launchctl kickstart -k "system/${DAEMON_LABEL}"
sleep 1

echo
echo "Effective settings:"
sudo -u "${BUILDER_USER}" bash -lc '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null; nix config show 2>/dev/null | grep -E "^(builders|builders-use-substitutes|trusted-users|external-builders) "' || true

echo
echo "Setup complete. Start the builder VM with:"
echo "    ./scripts/start-linux-builder.sh"
