#!/usr/bin/env bash
# =============================================================================
# OpenSpecimen Enterprise Edition — Fresh Install Script
# Target OS  : Ubuntu 24.04 LTS
# Stack      : Apache 2.4 + Java 17 + Tomcat 9 (bundled as tomcat-as) + MySQL 8.0
# Service    : Runs as dedicated user 'openspecimen'
# Usage      : sudo bash install_openspecimen.sh
# =============================================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0"

# ─── Fixed paths & names ─────────────────────────────────────────────────────
OS_USER="openspecimen"
BASE_DIR="/usr/local/openspecimen"
TOMCAT_DIR="${BASE_DIR}/tomcat-as"
DATA_DIR="${BASE_DIR}/data"
PLUGINS_DIR="${BASE_DIR}/plugins"
INSTALLER_DIR="${BASE_DIR}/installer"
LOG_FILE="/var/log/openspecimen_install.log"
APACHE_PORT=80
TOMCAT_PORT=8080

#─── Test input overrides (comment out after validation) ────────────────────
USE_TEST_INPUTS="true"
TEST_OS_DOWNLOAD_URL="https://build.openspecimen.org/download/openspecimen_v12.2.RC5.zip"
TEST_OS_DOWNLOAD_USER="os_build_user"
TEST_OS_DOWNLOAD_PASS="os_build_user"
TEST_MYSQL_ROOT_PASS="Root@12345"
TEST_OS_DB_NAME="openspecimen_test"
TEST_OS_DB_USER="openspecimen"
TEST_OS_DB_PASS="OpenSpecimen@12345"

# ─── Redirect all output to log as well ──────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo "  OpenSpecimen Enterprise Edition — Installer"
echo "  $(date)"
echo "============================================================"
echo ""

# =============================================================================
# SECTION 1 — Interactive input collection
# =============================================================================

collect_inputs() {
    info "Collecting installation parameters..."
    echo ""

    if [[ "${USE_TEST_INPUTS:-false}" == "true" ]]; then
        OS_DOWNLOAD_URL="${TEST_OS_DOWNLOAD_URL:-}"
        OS_DOWNLOAD_USER="${TEST_OS_DOWNLOAD_USER:-}"
        OS_DOWNLOAD_PASS="${TEST_OS_DOWNLOAD_PASS:-}"
        MYSQL_ROOT_PASS="${TEST_MYSQL_ROOT_PASS:-}"
        OS_DB_NAME="${TEST_OS_DB_NAME:-openspecimen}"
        OS_DB_USER="${TEST_OS_DB_USER:-osuser}"
        OS_DB_PASS="${TEST_OS_DB_PASS:-}"

        [[ -n "$OS_DOWNLOAD_URL" ]] || die "TEST_OS_DOWNLOAD_URL cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_DOWNLOAD_USER" ]] || die "TEST_OS_DOWNLOAD_USER cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_DOWNLOAD_PASS" ]] || die "TEST_OS_DOWNLOAD_PASS cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$MYSQL_ROOT_PASS" ]] || die "TEST_MYSQL_ROOT_PASS cannot be empty when USE_TEST_INPUTS=true."
        [[ -n "$OS_DB_PASS" ]] || die "TEST_OS_DB_PASS cannot be empty when USE_TEST_INPUTS=true."

        success "Using hardcoded test inputs."
        return
    fi

    read -rp  "  OpenSpecimen download URL          : " OS_DOWNLOAD_URL
    [[ -n "$OS_DOWNLOAD_URL" ]] || die "Download URL cannot be empty."

    read -rp  "  Download username                  : " OS_DOWNLOAD_USER
    [[ -n "$OS_DOWNLOAD_USER" ]] || die "Download username cannot be empty."

    read -rsp "  Download password                  : " OS_DOWNLOAD_PASS; echo ""
    [[ -n "$OS_DOWNLOAD_PASS" ]] || die "Download password cannot be empty."

    echo ""
    read -rsp "  MySQL root password                : " MYSQL_ROOT_PASS; echo ""
    [[ -n "$MYSQL_ROOT_PASS" ]] || die "MySQL root password cannot be empty."

    read -rp  "  OpenSpecimen DB name  [openspecimen]: " OS_DB_NAME
    OS_DB_NAME="${OS_DB_NAME:-openspecimen}"

    read -rp  "  OpenSpecimen DB user  [osuser]      : " OS_DB_USER
    OS_DB_USER="${OS_DB_USER:-osuser}"

    read -rsp "  OpenSpecimen DB password           : " OS_DB_PASS; echo ""
    [[ -n "$OS_DB_PASS" ]] || die "DB password cannot be empty."

    echo ""
    success "All inputs collected."
}

collect_inputs

# =============================================================================
# SECTION 2 — System preparation
# =============================================================================

info "Updating package lists..."
apt-get update -qq

info "Installing required packages..."
apt-get install -y -qq curl unzip python3

# =============================================================================
# SECTION 3 — Apache
# =============================================================================

install_apache() {
    if systemctl is-active --quiet apache2 2>/dev/null; then
        success "Apache already running — skipping install."
    else
        info "Installing Apache..."
        apt-get install -y -qq apache2
        systemctl enable apache2
        systemctl start apache2
        success "Apache installed and started."
    fi
}

install_apache

# =============================================================================
# SECTION 4 — Java 17
# =============================================================================

install_java() {
    if java -version 2>&1 | grep -q "17\."; then
        success "Java 17 already installed — skipping."
    else
        info "Installing OpenJDK 17..."
        apt-get install -y -qq openjdk-17-jdk openjdk-17-jre
        success "Java 17 installed."
    fi

    JAVA_HOME_PATH=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
    export JAVA_HOME="$JAVA_HOME_PATH"

    if [[ ! -f /etc/profile.d/java17.sh ]]; then
        cat > /etc/profile.d/java17.sh <<EOF
export JAVA_HOME=${JAVA_HOME_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    fi
}

install_java

# =============================================================================
# SECTION 5 — MySQL 8.0 + prerequisites
# =============================================================================

install_mysql() {
    local mysql_fresh_install=0
    local mysql_datadir="/var/lib/mysql"
    local os_mysql_cnf="/etc/mysql/mysql.conf.d/99-openspecimen.cnf"

    if ! systemctl is-active --quiet mysql 2>/dev/null; then
        info "Installing MySQL 8.0..."
        debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASS}"
        debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASS}"
        apt-get install -y -qq mysql-server
        systemctl enable mysql
        mysql_fresh_install=1
        success "MySQL 8.0 installed."
    else
        success "MySQL already running — skipping install."
    fi

    info "Applying MySQL prerequisites..."
    systemctl stop mysql 2>/dev/null || true

    cat > "$os_mysql_cnf" <<'EOF'
# --- OpenSpecimen required settings --- openspecimen_config
[client]
default-character-set=utf8mb4

[mysqld]
character-set-server=utf8mb4
lower_case_table_names=1
innodb_buffer_pool_size=2048M
log_bin_trust_function_creators=1
optimizer_search_depth=0
init_connect='SET collation_connection = utf8mb4_unicode_ci'
collation-server=utf8mb4_unicode_ci
EOF

    if [[ $mysql_fresh_install -eq 1 ]]; then
        info "Reinitializing MySQL data directory with lower_case_table_names=1..."
        find "$mysql_datadir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        mysqld --defaults-file=/etc/mysql/my.cnf --initialize-insecure --user=mysql --console
    fi

    systemctl start mysql

    if [[ $mysql_fresh_install -eq 1 ]]; then
        mysql --protocol=socket -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
    fi

    success "MySQL prerequisites applied."
}

install_mysql

# =============================================================================
# SECTION 6 — Create database and user
# =============================================================================

setup_database() {
    info "Creating database '${OS_DB_NAME}' and user '${OS_DB_USER}'..."
    mysql -uroot -p"${MYSQL_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${OS_DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${OS_DB_USER}'@'localhost' IDENTIFIED BY '${OS_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${OS_DB_NAME}\`.* TO '${OS_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    success "Database and user ready."
}

setup_database

# =============================================================================
# SECTION 7 — Service user & directory structure
# =============================================================================

setup_user_and_dirs() {
    if ! id "$OS_USER" &>/dev/null; then
        info "Creating service user '${OS_USER}'..."
        useradd --system --shell /bin/false --home-dir "$BASE_DIR" --create-home "$OS_USER"
        success "User '${OS_USER}' created."
    else
        info "User '${OS_USER}' already exists — skipping."
    fi

    mkdir -p "$DATA_DIR" "$PLUGINS_DIR" "$INSTALLER_DIR"
}

setup_user_and_dirs

# =============================================================================
# SECTION 8 — Download & extract OpenSpecimen build
# =============================================================================

download_and_extract() {
    local zip_file="${INSTALLER_DIR}/openspecimen.zip"

    info "Downloading OpenSpecimen Enterprise build..."
    info "Download progress will show percentage, transfer speed, and ETA."
    curl -fL --progress-bar \
        --user "${OS_DOWNLOAD_USER}:${OS_DOWNLOAD_PASS}" \
        -o "$zip_file" \
        "$OS_DOWNLOAD_URL" \
        || die "Download failed. Verify URL and credentials."

    info "Extracting build archive..."
    unzip -q -o "$zip_file" -d "$INSTALLER_DIR"

    OSPM_HOME=$(find "$INSTALLER_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -n "$OSPM_HOME" ]] || die "Could not locate extracted installer directory."

    # Extract the bundled tomcat-as zip directly into BASE_DIR
    local tomcat_zip
    tomcat_zip=$(find "$OSPM_HOME" -maxdepth 2 -name "tomcat-as*.zip" | head -1)
    [[ -n "$tomcat_zip" ]] || die "Bundled tomcat-as zip not found in the installer package."

    info "Extracting bundled tomcat-as..."
    unzip -q -o "$tomcat_zip" -d "$BASE_DIR"
    [[ -d "$TOMCAT_DIR" ]] || die "tomcat-as not found at ${TOMCAT_DIR} after extraction."

    export OSPM_HOME
    success "Build extracted. OSPM_HOME=${OSPM_HOME}"
}

download_and_extract

# =============================================================================
# SECTION 9 — Configure Tomcat
# =============================================================================

configure_tomcat() {
    # ── context.xml ──────────────────────────────────────────────────────────
    info "Configuring context.xml..."
    local context_xml="${TOMCAT_DIR}/conf/context.xml"
    cp -f "$context_xml" "${context_xml}.bak"

    python3 - <<PYEOF
with open("${context_xml}", "r") as f:
    content = f.read()

if "jdbc/openspecimen" not in content:
    inject = """
    <Resource name="jdbc/openspecimen" auth="Container" type="javax.sql.DataSource"
        maxActive="100" maxIdle="30" maxWait="10000"
        username="${OS_DB_USER}" password="${OS_DB_PASS}"
        driverClassName="com.mysql.cj.jdbc.Driver"
        url="jdbc:mysql://localhost:3306/${OS_DB_NAME}?useSSL=false&amp;allowPublicKeyRetrieval=true&amp;serverTimezone=UTC"
        testOnBorrow="true" validationQuery="select 1" />

    <Environment
        name="config/openspecimen"
        value="${TOMCAT_DIR}/conf/openspecimen.properties"
        type="java.lang.String"/>
"""
    content = content.replace("</Context>", inject + "\n</Context>")
    with open("${context_xml}", "w") as f:
        f.write(content)
PYEOF

    # ── setenv.sh ────────────────────────────────────────────────────────────
    info "Writing setenv.sh..."
    cat > "${TOMCAT_DIR}/bin/setenv.sh" <<EOF
export JAVA_OPTS="-Dfile.encoding=UTF-8 -Xms128m -Xmx2048m"
export CATALINA_OPTS="\$CATALINA_OPTS -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${TOMCAT_DIR}/bin -agentlib:jdwp=transport=dt_socket,address=*:8000,server=y,suspend=n"
CATALINA_PID=${TOMCAT_DIR}/bin/pid.txt
EOF
    chmod +x "${TOMCAT_DIR}/bin/setenv.sh"

    # ── catalina.sh — Java 17 JDK_JAVA_OPTIONS ───────────────────────────────
    info "Patching catalina.sh for Java 17..."
    local catalina="${TOMCAT_DIR}/bin/catalina.sh"
    if ! grep -q "add-opens=java.base/java.lang=ALL-UNNAMED" "$catalina"; then
        sed -i '/^# OS specific support/i \
# Add the JAVA 9 specific start-up parameters required by Tomcat\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.base/java.lang=ALL-UNNAMED"\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.base/java.io=ALL-UNNAMED"\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.base/java.util=ALL-UNNAMED"\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.base/java.util.concurrent=ALL-UNNAMED"\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED"\
JDK_JAVA_OPTIONS="$JDK_JAVA_OPTIONS --add-opens=java.base/java.net=ALL-UNNAMED"\
export JDK_JAVA_OPTIONS\
' "$catalina"
    fi

    success "Tomcat configured."
}

configure_tomcat

# =============================================================================
# SECTION 10 — Configure Apache
# =============================================================================

configure_apache() {
    local apache_site="/etc/apache2/sites-available/000-default.conf"

    info "Configuring Apache reverse proxy..."

    a2enmod proxy proxy_ajp >/dev/null

    cat > "$apache_site" <<'EOF'
<VirtualHost *:80>
    ServerName localhost

    ProxyPreserveHost On
    ProxyPass / ajp://localhost:8009/openspecimen/
    ProxyPassReverse / ajp://localhost:8009/openspecimen/
    ProxyPassReverseCookiePath /openspecimen /
</VirtualHost>
EOF

    a2dissite 000-default >/dev/null 2>&1 || true
    a2ensite 000-default >/dev/null
    systemctl reload apache2

    success "Apache reverse proxy configured."
}

configure_apache

# =============================================================================
# SECTION 11 — Configure openspecimen.properties (from ZIP)
# =============================================================================

configure_properties() {
    local props="${OSPM_HOME}/openspecimen.properties"
    [[ -f "$props" ]] || die "openspecimen.properties not found at ${props}"

    info "Configuring openspecimen.properties..."

    # Set or replace a key=value line (idempotent)
    set_prop() {
        local key="$1" val="$2"
        if grep -q "^${key}\s*=" "$props"; then
            sed -i "s|^${key}\s*=.*|${key}=${val}|" "$props"
        else
            echo "${key}=${val}" >> "$props"
        fi
    }

    set_prop "app.name"          "openspecimen"
    set_prop "tomcat.dir"        "${TOMCAT_DIR}"
    set_prop "app.data_dir"      "${DATA_DIR}"
    set_prop "app.log_conf"      ""
    set_prop "datasource.jndi"   "jdbc/openspecimen"
    set_prop "datasource.type"   "fresh"
    set_prop "database.type"     "mysql"
    set_prop "plugin.dir"        "${PLUGINS_DIR}"
    set_prop "app.audit_enabled" "true"

    success "openspecimen.properties configured."
}

configure_properties

# =============================================================================
# SECTION 12 — Run OpenSpecimen installer
# =============================================================================

run_installer() {
    info "Running OpenSpecimen install.sh..."
    cd "$OSPM_HOME"
    chmod +x install.sh
    bash install.sh "${OSPM_HOME}/openspecimen.properties"
    success "OpenSpecimen installer completed."
}

run_installer

# =============================================================================
# SECTION 13 — Permissions
# =============================================================================

set_permissions() {
    info "Setting ownership and permissions..."
    chown -R "${OS_USER}:${OS_USER}" "$BASE_DIR"
    chmod -R 750 "$TOMCAT_DIR"
    chmod -R 770 "$DATA_DIR" "$PLUGINS_DIR"
    find "${TOMCAT_DIR}/bin" -name "*.sh" -exec chmod +x {} \;
    success "Permissions set."
}

set_permissions

# =============================================================================
# SECTION 14 — systemd service
# =============================================================================

create_systemd_service() {
    info "Creating systemd service 'openspecimen'..."
    cat > /etc/systemd/system/openspecimen.service <<EOF
[Unit]
Description=OpenSpecimen (Tomcat 9)
After=network.target mysql.service
Requires=mysql.service

[Service]
Type=forking
User=${OS_USER}
Group=${OS_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="CATALINA_HOME=${TOMCAT_DIR}"
Environment="CATALINA_PID=${TOMCAT_DIR}/bin/pid.txt"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh -force
SuccessExitStatus=143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openspecimen
    systemctl start openspecimen
    success "openspecimen service enabled and started."
}

create_systemd_service

# =============================================================================
# SECTION 15 — Firewall (ufw)
# =============================================================================

configure_firewall() {
    info "Configuring ufw firewall..."
    command -v ufw &>/dev/null || apt-get install -y -qq ufw

    ufw allow OpenSSH
    ufw allow "${APACHE_PORT}/tcp"  comment "Apache HTTP"
    ufw allow "${TOMCAT_PORT}/tcp" comment "OpenSpecimen HTTP"
    ufw allow "8000/tcp"           comment "OpenSpecimen JDWP debug"

    ufw status | grep -q "Status: active" || ufw --force enable
    success "Firewall configured. Ports ${APACHE_PORT}, ${TOMCAT_PORT}, and 8000 open."
}

configure_firewall

# =============================================================================
# SECTION 16 — Cleanup
# =============================================================================

info "Cleaning up installer zip..."
rm -f "${INSTALLER_DIR}/openspecimen.zip"
success "Cleanup done."

# =============================================================================
# Done — Summary
# =============================================================================

echo ""
echo "============================================================"
echo -e "  ${GREEN}Installation complete!${NC}"
echo "============================================================"
echo "  URL           : http://$(hostname -I | awk '{print $1}'):${TOMCAT_PORT}/openspecimen"
echo "  Default login : admin / Login@123"
echo "  Base dir      : ${BASE_DIR}"
echo "  Data dir      : ${DATA_DIR}"
echo "  Tomcat dir    : ${TOMCAT_DIR}"
echo "  Install log   : ${LOG_FILE}"
echo ""
echo "  Service management:"
echo "    systemctl {status|start|stop|restart} openspecimen"
echo "============================================================"
echo ""
warn "Change the default admin password immediately after first login."
echo ""
