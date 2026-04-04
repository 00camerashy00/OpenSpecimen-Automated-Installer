#!/usr/bin/env bash

set -euo pipefail
umask 022

INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/openspecimen}"
INSTALLABLE_DIR="${INSTALLABLE_DIR:-/usr/local/openspecimen_installable}"
ENV_FILE="$INSTALLABLE_DIR/.installable_env"
ZIP_FILE="${ZIP_FILE:-/tmp/openspecimen.zip}"
OWNER_USER="${OWNER_USER:-${SUDO_USER:-${USER:-ubuntu}}}"
OWNER_GROUP="${OWNER_GROUP:-$(id -gn "$OWNER_USER" 2>/dev/null || echo "$OWNER_USER")}"

mkdir -p "$INSTALL_ROOT/data" "$INSTALL_ROOT/plugins" "$INSTALLABLE_DIR"
touch "$ENV_FILE"
chmod 755 "$INSTALL_ROOT" "$INSTALL_ROOT/data" "$INSTALL_ROOT/plugins" "$INSTALLABLE_DIR"
chmod 600 "$ENV_FILE"

read -r -p "OpenSpecimen download URL: " DOWNLOAD_URL
read -r -p "Username: " DOWNLOAD_USER
read -r -s -p "Password: " DOWNLOAD_PASSWORD
printf '\n'

curl -fL -u "${DOWNLOAD_USER}:${DOWNLOAD_PASSWORD}" "$DOWNLOAD_URL" -o "$ZIP_FILE"
unzip -oq "$ZIP_FILE" -d "$INSTALLABLE_DIR"
chmod -R u+rwX,go+rX "$INSTALLABLE_DIR"

if [[ "${EUID}" -eq 0 ]] && id "$OWNER_USER" >/dev/null 2>&1; then
  chown -R "$OWNER_USER:$OWNER_GROUP" "$INSTALL_ROOT" "$INSTALLABLE_DIR" "$ZIP_FILE"
fi

echo "Created:"
echo "  $INSTALL_ROOT"
echo "  $INSTALL_ROOT/data"
echo "  $INSTALL_ROOT/plugins"
echo "  $INSTALLABLE_DIR"
echo "  $ENV_FILE"
echo "  $ZIP_FILE"
echo "Downloaded and extracted the OpenSpecimen zip."
echo "Owner user for created files: $OWNER_USER"
