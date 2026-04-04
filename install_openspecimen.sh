#!/usr/bin/env bash

set -euo pipefail

INSTALL_ROOT="/usr/local/openspecimen"
INSTALLABLE_DIR="/usr/local/openspecimen_installable"
ENV_FILE="$INSTALLABLE_DIR/.installable_env"
ZIP_FILE="/tmp/openspecimen.zip"

[[ "${EUID}" -eq 0 ]] || { echo "Run this script with sudo or as root."; exit 1; }

mkdir -p "$INSTALL_ROOT/data" "$INSTALL_ROOT/plugins" "$INSTALLABLE_DIR"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

read -r -p "OpenSpecimen download URL: " DOWNLOAD_URL
read -r -p "Username: " DOWNLOAD_USER
read -r -s -p "Password: " DOWNLOAD_PASSWORD
printf '\n'

curl -fL -u "${DOWNLOAD_USER}:${DOWNLOAD_PASSWORD}" "$DOWNLOAD_URL" -o "$ZIP_FILE"
unzip -oq "$ZIP_FILE" -d "$INSTALLABLE_DIR"

echo "Created:"
echo "  $INSTALL_ROOT"
echo "  $INSTALL_ROOT/data"
echo "  $INSTALL_ROOT/plugins"
echo "  $INSTALLABLE_DIR"
echo "  $ENV_FILE"
echo "  $ZIP_FILE"
echo "Downloaded and extracted the OpenSpecimen zip."
