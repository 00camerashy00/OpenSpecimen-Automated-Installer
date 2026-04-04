#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

# Timestamp is used for backup file names when config files are updated.
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Default install locations. These can be overridden with environment variables.
INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/openspecimen}"
INSTALLABLE_DIR="${INSTALLABLE_DIR:-/usr/local/openspecimen_installable}"
ENV_FILE="${ENV_FILE:-$INSTALLABLE_DIR/.installable_env}"
ZIP_FILE="${ZIP_FILE:-/tmp/openspecimen.zip}"

# Ownership is normalized back to a real login user after privileged operations.
OWNER_USER="${OWNER_USER:-${SUDO_USER:-${USER:-ubuntu}}}"
OWNER_GROUP="${OWNER_GROUP:-$(id -gn "$OWNER_USER" 2>/dev/null || echo "$OWNER_USER")}"

# MySQL defaults for a fresh OpenSpecimen-style installation.
MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
MYSQL_CONF="${MYSQL_CONF:-/etc/mysql/mysql.conf.d/mysqld.cnf}"
MYSQL_ERROR_LOG="${MYSQL_ERROR_LOG:-/var/log/mysql/error.log}"
MYSQL_ROOT_HOST="${MYSQL_ROOT_HOST:-localhost}"
DB_NAME="${DB_NAME:-openspecimen_test}"
MYSQL_APP_USER="${MYSQL_APP_USER:-openspecimen}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-}"
FORCE_MYSQL_RESET="${FORCE_MYSQL_RESET:-0}"

DOWNLOAD_URL=""
DOWNLOAD_USER=""
DOWNLOAD_PASSWORD=""
MYSQL_WAS_PRESENT=0

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Run commands with root privileges only when needed. This lets the script be
# started by a regular user while still handling system-level installation work.
run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

load_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

# Persist only the MySQL credentials and database details needed by later steps.
# Download credentials are intentionally never written to disk.
save_env_file() {
  local tmp_file
  tmp_file="$(mktemp)"

  {
    printf '# OpenSpecimen installable environment\n'
    printf '# Generated on %s\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf 'MYSQL_ROOT_PASSWORD=%q\n' "$MYSQL_ROOT_PASSWORD"
    printf 'MYSQL_APP_USER=%q\n' "$MYSQL_APP_USER"
    printf 'MYSQL_APP_PASSWORD=%q\n' "$MYSQL_APP_PASSWORD"
    printf 'DB_NAME=%q\n' "$DB_NAME"
  } > "$tmp_file"

  run_root mkdir -p "$(dirname "$ENV_FILE")"
  run_root install -m 600 "$tmp_file" "$ENV_FILE"
  rm -f "$tmp_file"

  if id "$OWNER_USER" >/dev/null 2>&1; then
    run_root chown "$OWNER_USER:$OWNER_GROUP" "$ENV_FILE"
  fi
}

# Reuse existing values from the environment file when present; otherwise prompt.
prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-0}"
  local default_value="${4:-}"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ "$secret" -eq 1 ]]; then
    printf '%s: ' "$prompt_text"
    read -r -s current_value
    printf '\n'
  else
    if [[ -n "$default_value" ]]; then
      printf '%s [%s]: ' "$prompt_text" "$default_value"
    else
      printf '%s: ' "$prompt_text"
    fi
    read -r current_value
    current_value="${current_value:-$default_value}"
  fi

  [[ -n "$current_value" ]] || fail "$var_name cannot be empty."
  printf -v "$var_name" '%s' "$current_value"
}

# Collect download inputs for the current run and MySQL inputs for later reuse.
collect_inputs() {
  prompt_value "DOWNLOAD_URL" "OpenSpecimen download URL"
  prompt_value "DOWNLOAD_USER" "Download username"
  prompt_value "DOWNLOAD_PASSWORD" "Download password" 1
  prompt_value "DB_NAME" "Database name" 0 "openspecimen_test"
  prompt_value "MYSQL_APP_USER" "Database username" 0 "openspecimen"
  prompt_value "MYSQL_ROOT_PASSWORD" "New MySQL root password" 1
  prompt_value "MYSQL_APP_PASSWORD" "Password for MySQL user $MYSQL_APP_USER" 1
}

# Create the target directory structure expected by the installer.
prepare_directories() {
  run_root mkdir -p "$INSTALL_ROOT/data" "$INSTALL_ROOT/plugins" "$INSTALLABLE_DIR"
  run_root touch "$ENV_FILE"
  run_root chmod 755 "$INSTALL_ROOT" "$INSTALL_ROOT/data" "$INSTALL_ROOT/plugins" "$INSTALLABLE_DIR"
  run_root chmod 600 "$ENV_FILE"
}

# Some bundles extract with restrictive ownership or permissions. Normalize them
# so the working user can inspect and reuse the extracted installable files.
fix_installable_permissions() {
  run_root chmod -R u+rwX,go+rX "$INSTALLABLE_DIR"

  if id "$OWNER_USER" >/dev/null 2>&1; then
    run_root chown -R "$OWNER_USER:$OWNER_GROUP" "$INSTALL_ROOT" "$INSTALLABLE_DIR"
    [[ -e "$ZIP_FILE" ]] && run_root chown "$OWNER_USER:$OWNER_GROUP" "$ZIP_FILE"
  fi
}

# Install exact MySQL 8.0.45 from APT and fail fast if that version is missing.
install_required_packages() {
  local installed_state mysql_pkg_version mysql_client_version installed_version

  installed_state="$(dpkg-query -W -f='${Status}' mysql-server 2>/dev/null || true)"
  if [[ "$installed_state" == *"installed"* ]]; then
    MYSQL_WAS_PRESENT=1
  fi

  run_root env DEBIAN_FRONTEND=noninteractive apt-get update
  mysql_pkg_version="$(apt-cache madison mysql-server 2>/dev/null | awk '$3 ~ /^8\.0\.45/ {print $3; exit}')"
  mysql_client_version="$(apt-cache madison mysql-client 2>/dev/null | awk '$3 ~ /^8\.0\.45/ {print $3; exit}')"
  [[ -n "$mysql_pkg_version" ]] || fail "MySQL Server 8.0.45 is not available from the current APT sources."

  log "Installing curl, unzip, and MySQL Server 8.0.45"
  if [[ -n "$mysql_client_version" ]]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip "mysql-server=$mysql_pkg_version" "mysql-client=$mysql_client_version"
  else
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip "mysql-server=$mysql_pkg_version" mysql-client
  fi

  installed_version="$(mysql --version 2>/dev/null | sed -E 's/.*Distrib ([0-9.]+).*/\1/')"
  [[ "$installed_version" == 8.0.45* ]] || fail "Installed MySQL version is $installed_version, expected 8.0.45."
}

# Download the archive to /tmp and unpack it into the shared installable area.
download_and_extract() {
  log "Downloading OpenSpecimen zip to $ZIP_FILE"
  curl -fL -u "${DOWNLOAD_USER}:${DOWNLOAD_PASSWORD}" "$DOWNLOAD_URL" -o "$ZIP_FILE"

  log "Extracting zip into $INSTALLABLE_DIR"
  run_root unzip -oq "$ZIP_FILE" -d "$INSTALLABLE_DIR"
  fix_installable_permissions
}

backup_file() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    run_root cp -a "$file_path" "${file_path}.bak.${TIMESTAMP}"
  fi
}

# Update or append an INI-style key inside the requested section.
set_ini_value() {
  local file_path="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN {
      current = ""
      written = 0
      printed_section = 0
    }
    /^\[/ {
      if (current == section && !written) {
        print key "=" value
        written = 1
      }
      current = substr($0, 2, length($0) - 2)
      if (current == section) {
        printed_section = 1
      }
    }
    current == section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!written) {
        print key "=" value
        written = 1
      }
      next
    }
    { print }
    END {
      if (!printed_section) {
        print "[" section "]"
      }
      if (!written) {
        print key "=" value
      }
    }
  ' "$file_path" > "$tmp_file"

  run_root install -m 644 "$tmp_file" "$file_path"
  rm -f "$tmp_file"
}

# Apply the MySQL settings required by OpenSpecimen before initialization.
configure_mysql_cnf() {
  [[ -f "$MYSQL_CONF" ]] || fail "MySQL config file not found: $MYSQL_CONF"
  backup_file "$MYSQL_CONF"

  set_ini_value "$MYSQL_CONF" "mysqld" "lower_case_table_names" "1"
  set_ini_value "$MYSQL_CONF" "mysqld" "innodb_buffer_pool_size" "1536M"
  set_ini_value "$MYSQL_CONF" "mysqld" "log_bin_trust_function_creators" "1"
  set_ini_value "$MYSQL_CONF" "mysqld" "optimizer_search_depth" "0"
  set_ini_value "$MYSQL_CONF" "mysqld" "character-set-server" "utf8"
  set_ini_value "$MYSQL_CONF" "mysqld" "init_connect" "SET NAMES utf8 COLLATE utf8_unicode_ci"
  set_ini_value "$MYSQL_CONF" "mysqld" "collation-server" "utf8_unicode_ci"
  set_ini_value "$MYSQL_CONF" "client" "default-character-set" "utf8"
}

# Stop and start helpers are tolerant because service naming can vary slightly
# across Ubuntu images.
stop_mysql_service() {
  run_root service mysql stop >/dev/null 2>&1 || run_root systemctl stop mysql >/dev/null 2>&1 || true
}

start_mysql_service() {
  run_root service mysql start >/dev/null 2>&1 || run_root systemctl enable --now mysql >/dev/null 2>&1 || fail "Unable to start mysql service."
}

# Prepare runtime directories and log files before initializing a fresh datadir.
prepare_mysql_runtime() {
  run_root mkdir -p /var/run/mysqld
  run_root chown mysql:mysql /var/run/mysqld
  run_root mkdir -p "$(dirname "$MYSQL_ERROR_LOG")"
  run_root touch "$MYSQL_ERROR_LOG"
  run_root chmod 640 "$MYSQL_ERROR_LOG"
  if getent group adm >/dev/null 2>&1; then
    run_root chown mysql:adm "$MYSQL_ERROR_LOG"
  else
    run_root chown mysql:mysql "$MYSQL_ERROR_LOG"
  fi
}

# This installer is designed for a clean MySQL setup. Refuse to wipe an
# existing datadir unless the caller explicitly opts in.
reset_mysql_datadir() {
  local existing_entries

  existing_entries="$(find "$MYSQL_DATADIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$existing_entries" && "$MYSQL_WAS_PRESENT" -eq 1 && "$FORCE_MYSQL_RESET" != "1" ]]; then
    fail "Existing MySQL data detected in $MYSQL_DATADIR. Re-run with FORCE_MYSQL_RESET=1 only for a fresh host."
  fi

  run_root rm -rf "$MYSQL_DATADIR"
  run_root mkdir -p "$MYSQL_DATADIR"
  run_root chown mysql:mysql "$MYSQL_DATADIR"
  run_root chmod 700 "$MYSQL_DATADIR"
}

# Reinitialize MySQL from scratch, rotate the temporary root password, apply the
# secure-installation cleanup, and then create the application database/user.
initialize_mysql() {
  local mysqld_bin temp_password

  mysqld_bin="$(command -v mysqld || true)"
  [[ -n "$mysqld_bin" ]] || fail "mysqld binary not found."

  log "Re-initializing MySQL data directory"
  stop_mysql_service
  reset_mysql_datadir
  configure_mysql_cnf
  prepare_mysql_runtime
  [[ -S /var/run/mysqld/mysqld.sock ]] && run_root rm -f /var/run/mysqld/mysqld.sock

  run_root "$mysqld_bin" \
    --defaults-file=/etc/mysql/my.cnf \
    --initialize \
    --user=mysql \
    --datadir="$MYSQL_DATADIR" \
    --lower_case_table_names=1 \
    --log-error="$MYSQL_ERROR_LOG"

  start_mysql_service
  wait_for_mysql

  temp_password="$(extract_mysql_temp_password)"
  [[ -n "$temp_password" ]] || fail "Unable to find the temporary MySQL root password in $MYSQL_ERROR_LOG."

  rotate_mysql_root_password "$temp_password"
  secure_mysql_installation
  create_database_and_user
}

# Wait until the local MySQL socket responds before running SQL commands.
wait_for_mysql() {
  local attempt
  for attempt in {1..30}; do
    if mysqladmin --protocol=socket ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "MySQL did not become ready in time."
}

# MySQL writes an autogenerated root password to the error log after --initialize.
extract_mysql_temp_password() {
  grep -a 'temporary password' "$MYSQL_ERROR_LOG" 2>/dev/null | tail -n 1 | sed -E 's/.*root@localhost: //'
}

sql_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf '%s' "$value"
}

# Replace the temporary root password with the value captured from the user.
rotate_mysql_root_password() {
  local temp_password="$1"
  local escaped_password

  escaped_password="$(sql_escape "$MYSQL_ROOT_PASSWORD")"
  mysql --protocol=socket --connect-expired-password -uroot -p"$temp_password" <<SQL
ALTER USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${escaped_password}';
FLUSH PRIVILEGES;
SQL
}

# This is the scripted equivalent of the main cleanup steps from
# mysql_secure_installation, without the interactive prompts.
secure_mysql_installation() {
  mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<'SQL'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db LIKE 'test%';
FLUSH PRIVILEGES;
SQL
}

# Create the application database and grant the new user full access to it.
create_database_and_user() {
  local escaped_password

  escaped_password="$(sql_escape "$MYSQL_APP_PASSWORD")"
  mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${escaped_password}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${escaped_password}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

# Final summary keeps the operator-facing output short and explicit.
print_summary() {
  log "OpenSpecimen installable directory: $INSTALLABLE_DIR"
  log "OpenSpecimen zip file: $ZIP_FILE"
  log "MySQL database: $DB_NAME"
  log "MySQL app user: $MYSQL_APP_USER"
  log "Saved MySQL credentials in: $ENV_FILE"
  log "Download URL, username, and password were not saved."
}

main() {
  load_env_file
  collect_inputs
  prepare_directories
  save_env_file
  install_required_packages
  download_and_extract
  initialize_mysql
  print_summary
}

main "$@"
