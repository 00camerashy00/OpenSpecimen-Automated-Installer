#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/openspecimen}"
INSTALLABLE_DIR="${INSTALLABLE_DIR:-/usr/local/openspecimen_installable}"
EXTRACT_DIR="${EXTRACT_DIR:-$INSTALLABLE_DIR/extracted}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$INSTALLABLE_DIR/openspecimen.zip}"
LOG_DIR="${LOG_DIR:-$INSTALLABLE_DIR/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install_${TIMESTAMP}.log}"

APP_NAME="${APP_NAME:-openspecimen}"
DATA_DIR="${DATA_DIR:-$INSTALL_ROOT/data}"
PLUGIN_DIR="${PLUGIN_DIR:-$INSTALL_ROOT/plugins}"
TOMCAT_DIR="${TOMCAT_DIR:-$INSTALL_ROOT/tomcat-as}"
OS_PROPERTIES_DEST="${OS_PROPERTIES_DEST:-$TOMCAT_DIR/conf/openspecimen.properties}"

MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
MYSQL_CONF="${MYSQL_CONF:-/etc/mysql/mysql.conf.d/mysqld.cnf}"
MYSQL_ERROR_LOG="${MYSQL_ERROR_LOG:-/var/log/mysql/error.log}"
MYSQL_ROOT_HOST="${MYSQL_ROOT_HOST:-localhost}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
JDBC_RESOURCE_NAME="${JDBC_RESOURCE_NAME:-jdbc/openspecimen}"
CONFIG_ENV_NAME="${CONFIG_ENV_NAME:-config/openspecimen}"
FORCE_MYSQL_RESET="${FORCE_MYSQL_RESET:-0}"
STRICT_MYSQL_VERSION="${STRICT_MYSQL_VERSION:-0}"
NON_INTERACTIVE=0
RESET_ENV=0
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

DOWNLOAD_URL="${DOWNLOAD_URL:-}"
DOWNLOAD_USER="${DOWNLOAD_USER:-}"
DOWNLOAD_PASSWORD="${DOWNLOAD_PASSWORD:-}"
OS_ENV="${OS_ENV:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-}"
MYSQL_APP_USER="${MYSQL_APP_USER:-}"
DB_NAME="${DB_NAME:-}"
BUNDLED_TOMCAT_SOURCE="${BUNDLED_TOMCAT_SOURCE:-}"
INSTALLER_SCRIPT="${INSTALLER_SCRIPT:-}"

MYSQL_WAS_PRESENT=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./install_openspecimen.sh [options]

Options:
  --download-url URL            OpenSpecimen build zip URL
  --download-user USER          Download username
  --download-password PASS      Download password
  --env DEV|TEST|PROD           Deployment environment
  --mysql-root-password PASS    New MySQL root password to set after initialization
  --mysql-app-password PASS     Password for the OpenSpecimen MySQL user
  --app-name NAME               OpenSpecimen application name (default: openspecimen)
  --db-name NAME                Database name (default: lower-case env, e.g. dev)
  --db-user USER                Database user (default: openspecimen_db_<env>)
  --db-host HOST                Database host for Tomcat JDBC URL (default: 127.0.0.1)
  --db-port PORT                Database port for Tomcat JDBC URL (default: 3306)
  --archive PATH                Use an existing local zip instead of downloading
  --force-mysql-reset           Allow wiping an existing MySQL data directory
  --reset-env                   Delete saved .env inputs and prompt again
  --non-interactive             Fail instead of prompting for any missing values
  --strict-mysql-version        Abort if MySQL 8.0.45 is not available from APT
  --help                        Show this help

Environment variables with the same names can also be used.
EOF
}

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

debug() { log "DEBUG" "$*"; }
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
error() { log "ERROR" "$*"; }

fail() {
  error "$*"
  exit 1
}

run() {
  debug "Running: $*"
  "$@"
}

run_masked() {
  local masked_command="$1"
  shift
  debug "Running: $masked_command"
  "$@"
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this installer with sudo or as root."
  fi
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Installer log: $LOG_FILE"
}

trap_handler() {
  local exit_code="$?"
  if [[ "$exit_code" -ne 0 ]]; then
    error "Installation failed. Review $LOG_FILE for details."
  fi
}

trap trap_handler EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --download-url)
        DOWNLOAD_URL="$2"
        shift 2
        ;;
      --download-user)
        DOWNLOAD_USER="$2"
        shift 2
        ;;
      --download-password)
        DOWNLOAD_PASSWORD="$2"
        shift 2
        ;;
      --env)
        OS_ENV="$2"
        shift 2
        ;;
      --mysql-root-password)
        MYSQL_ROOT_PASSWORD="$2"
        shift 2
        ;;
      --mysql-app-password)
        MYSQL_APP_PASSWORD="$2"
        shift 2
        ;;
      --app-name)
        APP_NAME="$2"
        shift 2
        ;;
      --db-name)
        DB_NAME="$2"
        shift 2
        ;;
      --db-user)
        MYSQL_APP_USER="$2"
        shift 2
        ;;
      --db-host)
        DB_HOST="$2"
        shift 2
        ;;
      --db-port)
        DB_PORT="$2"
        shift 2
        ;;
      --archive)
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --force-mysql-reset)
        FORCE_MYSQL_RESET=1
        shift
        ;;
      --reset-env)
        RESET_ENV=1
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --strict-mysql-version)
        STRICT_MYSQL_VERSION=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

load_saved_env() {
  if [[ "$RESET_ENV" -eq 1 && -f "$ENV_FILE" ]]; then
    rm -f "$ENV_FILE"
    info "Removed saved installer inputs: $ENV_FILE"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    info "Loading saved installer inputs from $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

save_env_file() {
  local tmp_file
  tmp_file="$(mktemp)"

  {
    printf '# OpenSpecimen installer inputs\n'
    printf '# Generated on %s\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf 'DOWNLOAD_URL=%q\n' "$DOWNLOAD_URL"
    printf 'DOWNLOAD_USER=%q\n' "$DOWNLOAD_USER"
    printf 'DOWNLOAD_PASSWORD=%q\n' "$DOWNLOAD_PASSWORD"
    printf 'OS_ENV=%q\n' "$OS_ENV"
    printf 'MYSQL_ROOT_PASSWORD=%q\n' "$MYSQL_ROOT_PASSWORD"
    printf 'MYSQL_APP_PASSWORD=%q\n' "$MYSQL_APP_PASSWORD"
    printf 'MYSQL_APP_USER=%q\n' "$MYSQL_APP_USER"
    printf 'DB_NAME=%q\n' "$DB_NAME"
    printf 'APP_NAME=%q\n' "$APP_NAME"
    printf 'DB_HOST=%q\n' "$DB_HOST"
    printf 'DB_PORT=%q\n' "$DB_PORT"
  } > "$tmp_file"

  chmod 600 "$tmp_file"
  mv "$tmp_file" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  info "Saved installer inputs to $ENV_FILE"
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-0}"
  local default_value="${4:-}"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    fail "Missing required value for $var_name in non-interactive mode."
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

  if [[ -z "$current_value" ]]; then
    fail "$var_name cannot be empty."
  fi

  printf -v "$var_name" '%s' "$current_value"
}

ensure_download_inputs() {
  prompt_value "DOWNLOAD_URL" "Download URL"
  prompt_value "DOWNLOAD_USER" "Download username"
  prompt_value "DOWNLOAD_PASSWORD" "Download password" 1
}

collect_inputs() {
  if [[ ! -f "$ARCHIVE_PATH" || "$RESET_ENV" -eq 1 ]]; then
    ensure_download_inputs
  fi
  prompt_value "OS_ENV" "Environment (DEV, TEST, PROD)"

  OS_ENV="$(printf '%s' "$OS_ENV" | tr '[:lower:]' '[:upper:]')"
  case "$OS_ENV" in
    DEV|TEST|PROD) ;;
    *)
      fail "Environment must be one of DEV, TEST, or PROD."
      ;;
  esac

  local os_env_lower
  os_env_lower="$(printf '%s' "$OS_ENV" | tr '[:upper:]' '[:lower:]')"
  DB_NAME="${DB_NAME:-$os_env_lower}"
  MYSQL_APP_USER="${MYSQL_APP_USER:-openspecimen_db_${os_env_lower}}"

  prompt_value "MYSQL_ROOT_PASSWORD" "New MySQL root password" 1
  prompt_value "MYSQL_APP_PASSWORD" "Password for MySQL user ${MYSQL_APP_USER}" 1

  info "Using environment=$OS_ENV, database=$DB_NAME, database_user=$MYSQL_APP_USER, app_name=$APP_NAME"
}

backup_file() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    cp -a "$file_path" "${file_path}.bak.${TIMESTAMP}"
    debug "Backup created: ${file_path}.bak.${TIMESTAMP}"
  fi
}

sql_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf '%s' "$value"
}

text_preview() {
  local file_path="$1"
  head -c 512 "$file_path" 2>/dev/null | LC_ALL=C tr -cd '\11\12\15\40-\176'
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

set_kv_property() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN {
      pattern = "^[[:space:]]*" key "[[:space:]]*="
      written = 0
    }
    $0 ~ pattern {
      if (!written) {
        print key "=" value
        written = 1
      }
      next
    }
    { print }
    END {
      if (!written) {
        print key "=" value
      }
    }
  ' "$file_path" > "$tmp_file"
  mv "$tmp_file" "$file_path"
}

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
  mv "$tmp_file" "$file_path"
}

prepare_directories() {
  mkdir -p "$(dirname "$ARCHIVE_PATH")" "$INSTALLABLE_DIR" "$EXTRACT_DIR" "$INSTALL_ROOT" "$DATA_DIR" "$DATA_DIR/logs" "$PLUGIN_DIR"
  chmod 755 "$INSTALL_ROOT"
  chmod 755 "$DATA_DIR" "$DATA_DIR/logs" "$PLUGIN_DIR"
}

apt_install_common_packages() {
  export DEBIAN_FRONTEND=noninteractive
  info "Installing base packages, Java 17, and unzip tooling"
  run apt-get update
  run apt-get install -y ca-certificates curl unzip openjdk-17-jdk openjdk-17-jre
}

install_mysql_server() {
  local installed_state mysql_pkg_version mysql_client_version mysql_version_line installed_version

  installed_state="$(dpkg-query -W -f='${Status}' mysql-server 2>/dev/null || true)"
  if [[ "$installed_state" == *"installed"* ]]; then
    MYSQL_WAS_PRESENT=1
  fi

  mysql_pkg_version="$(apt-cache madison mysql-server 2>/dev/null | awk '$3 ~ /^8\.0\.45/ {print $3; exit}')"
  mysql_client_version="$(apt-cache madison mysql-client 2>/dev/null | awk '$3 ~ /^8\.0\.45/ {print $3; exit}')"

  if [[ -n "$mysql_pkg_version" ]]; then
    info "Installing MySQL using the available 8.0.45 package version: $mysql_pkg_version"
    if [[ -n "$mysql_client_version" ]]; then
      run apt-get install -y "mysql-server=$mysql_pkg_version" "mysql-client=$mysql_client_version"
    else
      run apt-get install -y "mysql-server=$mysql_pkg_version" mysql-client
    fi
  else
    if [[ "$STRICT_MYSQL_VERSION" -eq 1 ]]; then
      fail "mysql-server 8.0.45 is not available from the current APT sources."
    fi
    warn "mysql-server 8.0.45 is not available from the current APT sources. Installing the repository default version instead."
    run apt-get install -y mysql-server mysql-client
  fi

  mysql_version_line="$(mysql --version)"
  installed_version="$(printf '%s\n' "$mysql_version_line" | sed -E 's/.*Distrib ([0-9.]+).*/\1/')"
  if [[ "$installed_version" != 8.0.45* ]]; then
    warn "Installed MySQL version is $installed_version. Requirement requested 8.0.45."
  else
    info "Confirmed MySQL version: $installed_version"
  fi
}

stop_mysql_service() {
  if systemctl list-unit-files | grep -q '^mysql\.service'; then
    run systemctl stop mysql || true
  elif systemctl list-unit-files | grep -q '^mysqld\.service'; then
    run systemctl stop mysqld || true
  fi
}

start_mysql_service() {
  if systemctl list-unit-files | grep -q '^mysql\.service'; then
    run systemctl enable mysql
    run systemctl start mysql
  elif systemctl list-unit-files | grep -q '^mysqld\.service'; then
    run systemctl enable mysqld
    run systemctl start mysqld
  else
    fail "Could not find a MySQL systemd service."
  fi
}

prepare_mysql_logs() {
  mkdir -p "$(dirname "$MYSQL_ERROR_LOG")"
  touch "$MYSQL_ERROR_LOG"
  chmod 640 "$MYSQL_ERROR_LOG"
  if getent group adm >/dev/null 2>&1; then
    chown mysql:adm "$MYSQL_ERROR_LOG"
  else
    chown mysql:mysql "$MYSQL_ERROR_LOG"
  fi
}

reset_mysql_datadir() {
  local existing_entries

  existing_entries="$(find "$MYSQL_DATADIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$existing_entries" && "$MYSQL_WAS_PRESENT" -eq 1 && "$FORCE_MYSQL_RESET" -ne 1 ]]; then
    fail "Existing MySQL data detected in $MYSQL_DATADIR. Re-run with --force-mysql-reset only if this host is meant for a fresh install."
  fi

  rm -rf "$MYSQL_DATADIR"
  mkdir -p "$MYSQL_DATADIR"
  chown mysql:mysql "$MYSQL_DATADIR"
  chmod 700 "$MYSQL_DATADIR"
}

configure_mysql_cnf() {
  [[ -f "$MYSQL_CONF" ]] || fail "MySQL config file not found: $MYSQL_CONF"
  backup_file "$MYSQL_CONF"

  set_ini_value "$MYSQL_CONF" "mysqld" "lower_case_table_names" "1"
  set_ini_value "$MYSQL_CONF" "mysqld" "innodb_buffer_pool_size" "1536M"
  set_ini_value "$MYSQL_CONF" "mysqld" "log_bin_trust_function_creators" "1"
  set_ini_value "$MYSQL_CONF" "mysqld" "optimizer_search_depth" "0"
  set_ini_value "$MYSQL_CONF" "mysqld" "character-set-server" "utf8"
  set_ini_value "$MYSQL_CONF" "mysqld" "collation-server" "utf8_unicode_ci"

  debug "MySQL configuration updated in $MYSQL_CONF"
}

initialize_mysql() {
  local mysqld_bin temp_password

  mysqld_bin="$(command -v mysqld || true)"
  [[ -n "$mysqld_bin" ]] || fail "mysqld binary not found after MySQL installation."

  info "Resetting and initializing MySQL data directory"
  stop_mysql_service
  reset_mysql_datadir
  configure_mysql_cnf
  prepare_mysql_logs

  if [[ -S /var/run/mysqld/mysqld.sock ]]; then
    rm -f /var/run/mysqld/mysqld.sock
  fi

  run "$mysqld_bin" \
    --defaults-file=/etc/mysql/my.cnf \
    --initialize \
    --user=mysql \
    --datadir="$MYSQL_DATADIR" \
    --lower_case_table_names=1 \
    --log-error="$MYSQL_ERROR_LOG"

  start_mysql_service
  sleep 5

  temp_password="$(extract_mysql_temp_password)"
  [[ -n "$temp_password" ]] || fail "Could not extract MySQL temporary password from $MYSQL_ERROR_LOG."

  rotate_mysql_root_password "$temp_password"
  create_openspecimen_database
}

extract_mysql_temp_password() {
  local password
  password="$(grep -a 'temporary password' "$MYSQL_ERROR_LOG" 2>/dev/null | tail -n 1 | sed -E 's/.*root@localhost: //')"
  printf '%s' "$password"
}

rotate_mysql_root_password() {
  local temp_password="$1"
  local escaped_password

  escaped_password="$(sql_escape "$MYSQL_ROOT_PASSWORD")"
  info "Setting the MySQL root password"
  mysql --protocol=socket \
    --connect-expired-password \
    -uroot \
    -p"$temp_password" <<SQL
ALTER USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${escaped_password}';
FLUSH PRIVILEGES;
SQL
}

create_openspecimen_database() {
  local escaped_password

  escaped_password="$(sql_escape "$MYSQL_APP_PASSWORD")"
  info "Creating OpenSpecimen database and application user"
  mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${escaped_password}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${escaped_password}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

download_openspecimen() {
  if [[ -f "$ARCHIVE_PATH" ]] && validate_zip_archive "$ARCHIVE_PATH"; then
    info "Reusing existing archive: $ARCHIVE_PATH"
    return
  fi

  if [[ -f "$ARCHIVE_PATH" ]]; then
    warn "Existing archive is not a valid ZIP: $ARCHIVE_PATH"
    describe_invalid_archive "$ARCHIVE_PATH"
    mv "$ARCHIVE_PATH" "${ARCHIVE_PATH}.invalid.${TIMESTAMP}"
    warn "Moved invalid archive to ${ARCHIVE_PATH}.invalid.${TIMESTAMP}"
  fi

  ensure_download_inputs

  info "Downloading OpenSpecimen archive to $ARCHIVE_PATH"
  run_masked \
    "curl --fail --show-error --location -u ${DOWNLOAD_USER}:******** \"$DOWNLOAD_URL\" -o \"$ARCHIVE_PATH\"" \
    curl --fail --show-error --location -u "${DOWNLOAD_USER}:${DOWNLOAD_PASSWORD}" "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"

  if ! validate_zip_archive "$ARCHIVE_PATH"; then
    describe_invalid_archive "$ARCHIVE_PATH"
    fail "Downloaded file is not a valid ZIP archive. Check the URL, username/password, and whether the link returns the actual OpenSpecimen build instead of an HTML login or error page."
  fi
}

extract_archive() {
  info "Extracting archive into $EXTRACT_DIR"
  validate_zip_archive "$ARCHIVE_PATH" || fail "Archive validation failed for $ARCHIVE_PATH"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  run unzip -oq "$ARCHIVE_PATH" -d "$EXTRACT_DIR"
}

validate_zip_archive() {
  local file_path="$1"
  [[ -f "$file_path" ]] || return 1
  unzip -tq "$file_path" >/dev/null 2>&1
}

describe_invalid_archive() {
  local file_path="$1"
  local preview file_size

  file_size="$(stat -c '%s bytes' "$file_path" 2>/dev/null || printf 'unknown size')"
  preview="$(text_preview "$file_path")"

  warn "Archive check failed for $file_path ($file_size)"
  if [[ -n "$preview" ]]; then
    warn "File preview: ${preview//$'\n'/ }"
  fi
}

find_first() {
  local search_root="$1"
  shift
  find "$search_root" "$@" -print 2>/dev/null | head -n 1 || true
}

is_tomcat_home_dir() {
  local dir_path="$1"
  [[ -d "$dir_path" && -d "$dir_path/bin" && -d "$dir_path/conf" ]]
}

detect_tomcat_root() {
  local search_root="$1"
  local named_dir

  named_dir="$(find_first "$search_root" -type d \( -name 'apache-tomcat*' -o -name 'tomcat-as' \))"
  if [[ -n "$named_dir" ]]; then
    printf '%s' "$named_dir"
    return 0
  fi

  if is_tomcat_home_dir "$search_root"; then
    printf '%s' "$search_root"
    return 0
  fi

  find "$search_root" -type d 2>/dev/null | while read -r dir_path; do
    if is_tomcat_home_dir "$dir_path"; then
      printf '%s\n' "$dir_path"
      break
    fi
  done
}

detect_bundle_layout() {
  INSTALLER_SCRIPT="$(find_first "$EXTRACT_DIR" -type f -name install.sh)"
  BUNDLED_TOMCAT_SOURCE="$(detect_tomcat_root "$EXTRACT_DIR")"

  if [[ -z "$INSTALLER_SCRIPT" ]]; then
    fail "Could not find install.sh in the extracted OpenSpecimen bundle."
  fi

  if [[ -z "$BUNDLED_TOMCAT_SOURCE" ]]; then
    local tomcat_archive
    tomcat_archive="$(find "$EXTRACT_DIR" -type f \( -name 'apache-tomcat*.zip' -o -name 'apache-tomcat*.tar.gz' -o -name 'apache-tomcat*.tgz' -o -name 'tomcat-as.zip' -o -name 'tomcat-as.tar.gz' -o -name 'tomcat-as.tgz' \) -print 2>/dev/null | head -n 1 || true)"
    if [[ -n "$tomcat_archive" ]]; then
      local temp_tomcat_extract
      temp_tomcat_extract="$(mktemp -d)"
      case "$tomcat_archive" in
        *.zip)
          run unzip -oq "$tomcat_archive" -d "$temp_tomcat_extract"
          ;;
        *.tar.gz|*.tgz)
          run tar -xzf "$tomcat_archive" -C "$temp_tomcat_extract"
          ;;
      esac
      BUNDLED_TOMCAT_SOURCE="$(detect_tomcat_root "$temp_tomcat_extract")"
    fi
  fi

  [[ -n "$BUNDLED_TOMCAT_SOURCE" ]] || fail "Could not find a bundled Tomcat directory or Tomcat archive in the OpenSpecimen zip. Expected names like tomcat-as.zip, tomcat-as, or apache-tomcat*."
}

install_tomcat_bundle() {
  info "Installing bundled Tomcat into $TOMCAT_DIR"
  if [[ -d "$TOMCAT_DIR" ]]; then
    mv "$TOMCAT_DIR" "${TOMCAT_DIR}.bak.${TIMESTAMP}"
    warn "Existing Tomcat directory moved to ${TOMCAT_DIR}.bak.${TIMESTAMP}"
  fi

  mkdir -p "$TOMCAT_DIR"
  cp -a "$BUNDLED_TOMCAT_SOURCE"/. "$TOMCAT_DIR"/
  mkdir -p "$TOMCAT_DIR/conf" "$TOMCAT_DIR/bin" "$TOMCAT_DIR/temp"
  chmod +x "$TOMCAT_DIR"/bin/*.sh 2>/dev/null || true
}

install_java17() {
  local java_home

  java_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  info "Configuring Tomcat for Java 17 using JAVA_HOME=$java_home"

  backup_file "$TOMCAT_DIR/bin/setenv.sh"
  cat > "$TOMCAT_DIR/bin/setenv.sh" <<EOF
#!/usr/bin/env bash
export JAVA_HOME="$java_home"
export JAVA_OPTS="-Dfile.encoding=UTF-8 -Xms28m -Xmx2048m"
export CATALINA_OPTS="\${CATALINA_OPTS:-} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$TOMCAT_DIR/bin"
export JDK_JAVA_OPTIONS="\${JDK_JAVA_OPTIONS:-} --add-opens=java.base/java.net=ALL-UNNAMED"
export CATALINA_PID="$TOMCAT_DIR/temp/catalina.pid"
EOF
  chmod 755 "$TOMCAT_DIR/bin/setenv.sh"
}

detect_mysql_driver_class() {
  if find "$EXTRACT_DIR" "$TOMCAT_DIR" -type f \( -name 'mysql-connector-j-8*.jar' -o -name 'mysql-connector-java-8*.jar' \) -print -quit 2>/dev/null | grep -q .; then
    printf '%s' 'com.mysql.cj.jdbc.Driver'
  else
    printf '%s' 'com.mysql.jdbc.Driver'
  fi
}

configure_tomcat_context() {
  local driver_class jdbc_url xml_db_user xml_db_password xml_jdbc_url xml_properties_dest

  driver_class="$(detect_mysql_driver_class)"
  jdbc_url="jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false"
  xml_db_user="$(xml_escape "$MYSQL_APP_USER")"
  xml_db_password="$(xml_escape "$MYSQL_APP_PASSWORD")"
  xml_jdbc_url="$(xml_escape "$jdbc_url")"
  xml_properties_dest="$(xml_escape "$OS_PROPERTIES_DEST")"

  info "Writing Tomcat context.xml for JDBC resource $JDBC_RESOURCE_NAME"
  backup_file "$TOMCAT_DIR/conf/context.xml"
  cat > "$TOMCAT_DIR/conf/context.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Context>
  <Resource
      name="$JDBC_RESOURCE_NAME"
      auth="Container"
      type="javax.sql.DataSource"
      maxActive="100"
      maxIdle="30"
      maxWait="10000"
      username="$xml_db_user"
      password="$xml_db_password"
      driverClassName="$driver_class"
      url="$xml_jdbc_url"
      testOnBorrow="true"
      validationQuery="select 1 from dual" />
  <Environment
      name="$CONFIG_ENV_NAME"
      value="$xml_properties_dest"
      type="java.lang.String" />
</Context>
EOF
}

configure_openspecimen_properties() {
  local source_properties

  source_properties="$(find_first "$EXTRACT_DIR" -type f -name openspecimen.properties)"
  mkdir -p "$(dirname "$OS_PROPERTIES_DEST")"

  if [[ -n "$source_properties" ]]; then
    cp -a "$source_properties" "$OS_PROPERTIES_DEST"
  else
    warn "openspecimen.properties was not found in the zip. Creating a minimal one."
    : > "$OS_PROPERTIES_DEST"
  fi

  set_kv_property "$OS_PROPERTIES_DEST" "app.name" "$APP_NAME"
  set_kv_property "$OS_PROPERTIES_DEST" "tomcat.dir" "$TOMCAT_DIR"
  set_kv_property "$OS_PROPERTIES_DEST" "app.data_dir" "$DATA_DIR"
  set_kv_property "$OS_PROPERTIES_DEST" "app.log_conf" "$DATA_DIR/logs"
  set_kv_property "$OS_PROPERTIES_DEST" "datasource.jndi" "$JDBC_RESOURCE_NAME"
  set_kv_property "$OS_PROPERTIES_DEST" "datasource.type" "fresh"
  set_kv_property "$OS_PROPERTIES_DEST" "database.type" "mysql"
  set_kv_property "$OS_PROPERTIES_DEST" "plugin.dir" "$PLUGIN_DIR"
}

run_openspecimen_installer() {
  local installer_dir

  installer_dir="$(dirname "$INSTALLER_SCRIPT")"
  info "Running bundled OpenSpecimen installer"
  chmod +x "$INSTALLER_SCRIPT"
  (
    cd "$installer_dir"
    ./install.sh "$OS_PROPERTIES_DEST"
  )
}

start_tomcat_if_needed() {
  if pgrep -f "$TOMCAT_DIR" >/dev/null 2>&1; then
    info "Tomcat already appears to be running."
    return
  fi

  if [[ -x "$TOMCAT_DIR/bin/startup.sh" ]]; then
    info "Starting Tomcat"
    "$TOMCAT_DIR/bin/startup.sh"
    sleep 5
  else
    warn "startup.sh was not found in $TOMCAT_DIR/bin. Start Tomcat manually if the OpenSpecimen installer did not start it."
  fi
}

print_summary() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  printf '\n'
  info "OpenSpecimen installation flow completed."
  info "Archive: $ARCHIVE_PATH"
  info "Install root: $INSTALL_ROOT"
  info "Tomcat dir: $TOMCAT_DIR"
  info "Database: $DB_NAME"
  info "Database user: $MYSQL_APP_USER"
  info "Properties: $OS_PROPERTIES_DEST"
  if [[ -n "$host_ip" ]]; then
    info "Expected URL: http://$host_ip:8080/$APP_NAME"
  else
    info "Expected URL: http://<server-ip>:8080/$APP_NAME"
  fi
}

main() {
  ensure_root
  parse_args "$@"
  setup_logging
  load_saved_env
  parse_args "$@"
  collect_inputs
  save_env_file
  prepare_directories
  apt_install_common_packages
  download_openspecimen
  extract_archive
  detect_bundle_layout
  install_tomcat_bundle
  install_java17
  install_mysql_server
  initialize_mysql
  configure_tomcat_context
  configure_openspecimen_properties
  run_openspecimen_installer
  start_tomcat_if_needed
  print_summary
}

main "$@"
