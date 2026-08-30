#!/usr/bin/env bash
# bento — Phase 0, step 2: configure darwin.linux-builder as the aarch64-linux builder.
#
# Run with sudo:   sudo ./scripts/setup-linux-builder.sh
#
# Why this script exists instead of the stock nixpkgs instructions:
#   1. Determinate Nix OWNS /etc/nix/nix.conf and rewrites it on upgrade. User settings
#      must live in /etc/nix/nix.custom.conf, which nix.conf pulls in via `!include`.
#   2. The nixpkgs docs say to restart `org.nixos.nix-daemon`. On Determinate Nix the
#      launchd label is `systems.determinate.nix-daemon` — the documented command is a
#      silent no-op here.
#   3. We must REMOVE the `external-builders` config we tried first: Determinate's
#      Native Linux Builder is licence-gated and returns HTTP 400, and while that
#      setting is present it hijacks Linux builds instead of letting them fall through
#      to the remote builder configured below.
#
# Idempotent: safe to re-run.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "error: run me with sudo" >&2
  exit 1
fi

BUILDER_USER="${SUDO_USER:-chime}"
CUSTOM_CONF=/etc/nix/nix.custom.conf
SSH_CONF_DIR=/etc/ssh/ssh_config.d
SSH_CONF="${SSH_CONF_DIR}/100-linux-builder.conf"
DAEMON_LABEL=systems.determinate.nix-daemon

# The builder VM's publicly-known SSH *host* key, base64-encoded, as published in the
# nixpkgs manual. Safe here: the builder listens on localhost only. Do not expose the
# builder to other machines without replacing this.
HOST_KEY_B64='c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo='

echo "==> Backing up ${CUSTOM_CONF}"
if [[ -f ${CUSTOM_CONF} ]]; then
  cp -p "${CUSTOM_CONF}" "${CUSTOM_CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

echo "==> Rewriting ${CUSTOM_CONF} (dropping external-builders, adding remote builder)"
# Keep any pre-existing lines that are not ours and not the dead external-builders ones.
tmp=$(mktemp)
if [[ -f ${CUSTOM_CONF} ]]; then
  grep -v -E '^\s*(external-builders|extra-experimental-features\s*=\s*external-builders|extra-trusted-users|builders|builders-use-substitutes)\b' \
    "${CUSTOM_CONF}" > "${tmp}" || true
fi

cat >> "${tmp}" <<EOF

# --- bento: aarch64-linux remote builder (darwin.linux-builder) ---
extra-trusted-users = ${BUILDER_USER}
builders = ssh-ng://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 4 - - - ${HOST_KEY_B64}
builders-use-substitutes = true
EOF

install -m 0644 -o root -g wheel "${tmp}" "${CUSTOM_CONF}"
rm -f "${tmp}"

echo "==> Writing ${SSH_CONF} (builder listens on port 31022, not 22)"
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

echo
echo "Done. Effective settings:"
sleep 1
su - "${BUILDER_USER}" -c '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null; nix config show 2>/dev/null | grep -E "^(builders|builders-use-substitutes|trusted-users|external-builders) "' || true

echo
echo "Next: start the builder VM in its own terminal and LEAVE IT RUNNING:"
echo "    nix run nixpkgs#darwin.linux-builder"
echo "(it will ask for your sudo password once, to install /etc/nix/builder_ed25519)"
echo "Stop it later by typing 'shutdown now' at the builder@nixos prompt."
