#!/bin/bash
#
# kanban-mcp install script
# Installs kanban-mcp (via pipx), sets up MySQL (local, remote, or Docker),
# and writes the .env config file.
#
# Interactive (default):
#   ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#
# Non-interactive:
#   ./install.sh --auto                        # local MySQL, socket auth
#   ./install.sh --auto --docker               # MySQL via Docker
#   ./install.sh --auto --db-host remote.host  # remote MySQL
#
# Options:
#   --auto            Non-interactive mode (no prompts)
#   --docker          Use Docker for MySQL (starts docker compose stack)
#   --db-host HOST    MySQL host (default: localhost)
#   --with-semantic   Also install semantic search dependencies
#
# Environment variables (for --auto mode):
#   KANBAN_DB_NAME, KANBAN_DB_USER, KANBAN_DB_PASSWORD, KANBAN_DB_HOST,
#   MYSQL_ROOT_USER, MYSQL_ROOT_PASSWORD

set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/multidimensionalcats/kanban-mcp/main"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kanban-mcp"

AUTO=false
USE_DOCKER=false
WITH_SEMANTIC=false
DB_HOST_ARG=""

for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=true ;;
        --docker) USE_DOCKER=true ;;
        --with-semantic) WITH_SEMANTIC=true ;;
        --db-host)
            # handled below with shift
            ;;
        --help|-h)
            echo "Usage: ./install.sh [--auto] [--docker] [--db-host HOST] [--with-semantic]"
            echo ""
            echo "Options:"
            echo "  --auto            Non-interactive mode (uses env vars or defaults)"
            echo "  --docker          Use Docker for MySQL"
            echo "  --db-host HOST    MySQL host (default: localhost)"
            echo "  --with-semantic   Also install semantic search dependencies"
            echo ""
            echo "Environment variables (for --auto mode):"
            echo "  KANBAN_DB_NAME       Database name (default: kanban)"
            echo "  KANBAN_DB_USER       Database user (default: kanban)"
            echo "  KANBAN_DB_PASSWORD   Database password (auto-generated if unset)"
            echo "  KANBAN_DB_HOST       Database host (default: localhost)"
            echo "  MYSQL_ROOT_USER      MySQL admin user for setup (default: root)"
            echo "  MYSQL_ROOT_PASSWORD  MySQL admin password (prompted if unset in interactive mode)"
            exit 0
            ;;
    esac
done

# Parse --db-host with its value
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-host)
            DB_HOST_ARG="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "=== kanban-mcp Install ==="
echo

# ─── Helper functions ───────────────────────────────────────────────

check_python() {
    if command -v python3 &>/dev/null; then
        PYTHON=python3
    elif command -v python &>/dev/null; then
        PYTHON=python
    else
        echo "Error: Python 3.10+ is required but not found."
        echo "Install Python from https://www.python.org/downloads/"
        exit 1
    fi

    local ver
    ver=$($PYTHON -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 10 ]; }; then
        echo "Error: Python 3.10+ is required (found $ver)."
        exit 1
    fi
    echo "Found Python $ver"
}

check_pipx() {
    if command -v pipx &>/dev/null; then
        echo "Found pipx"
        return 0
    fi
    return 1
}

install_pipx() {
    echo "Installing pipx..."
    $PYTHON -m pip install --user pipx 2>/dev/null || $PYTHON -m pip install pipx 2>/dev/null || {
        echo "Error: Could not install pipx. Install it manually:"
        echo "  https://pipx.pypa.io/stable/installation/"
        exit 1
    }
    $PYTHON -m pipx ensurepath 2>/dev/null || pipx ensurepath 2>/dev/null || true
    # Re-check PATH
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v pipx &>/dev/null; then
        echo "pipx installed but not in PATH. You may need to restart your shell."
        echo "Continuing with: $PYTHON -m pipx"
    fi
}

install_kanban_mcp() {
    local pkg="kanban-mcp"
    if [ "$WITH_SEMANTIC" = true ]; then
        pkg="kanban-mcp[semantic]"
    fi
    echo "Installing $pkg via pipx..."
    if command -v pipx &>/dev/null; then
        pipx install "$pkg"
    else
        $PYTHON -m pipx install "$pkg"
    fi
    echo "kanban-mcp installed."
}

check_mysql_running() {
    local host="${1:-localhost}"
    local port="${2:-3306}"
    # Try multiple methods to check MySQL reachability
    if command -v mysqladmin &>/dev/null; then
        mysqladmin ping -h "$host" -P "$port" --connect-timeout=2 &>/dev/null && return 0
    fi
    if command -v mysql &>/dev/null; then
        mysql -h "$host" -P "$port" -u root --connect-timeout=2 -e "SELECT 1" &>/dev/null 2>&1 && return 0
    fi
    # Fallback: try TCP connection
    if command -v nc &>/dev/null; then
        nc -z -w2 "$host" "$port" &>/dev/null && return 0
    fi
    if [ -e /dev/tcp/"$host"/"$port" ] 2>/dev/null; then
        (echo >/dev/tcp/"$host"/"$port") &>/dev/null && return 0
    fi
    return 1
}

check_docker() {
    command -v docker &>/dev/null && docker compose version &>/dev/null
}

download_docker_files() {
    local docker_dir="$CONFIG_DIR/docker"
    mkdir -p "$docker_dir"

    echo "Downloading Docker files..."
    curl -fsSL "$GITHUB_RAW/docker-compose.yml" -o "$docker_dir/docker-compose.yml"
    curl -fsSL "$GITHUB_RAW/Dockerfile" -o "$docker_dir/Dockerfile"
    curl -fsSL "$GITHUB_RAW/pyproject.toml" -o "$docker_dir/pyproject.toml"

    # Download migrations
    mkdir -p "$docker_dir/kanban_mcp/migrations"
    # Download __init__.py for the package
    curl -fsSL "$GITHUB_RAW/kanban_mcp/__init__.py" -o "$docker_dir/kanban_mcp/__init__.py"
    for migration in 001_initial_schema.sql 002_add_fulltext_search.sql 003_add_embeddings.sql 004_add_cascades_and_indexes.sql; do
        curl -fsSL "$GITHUB_RAW/kanban_mcp/migrations/$migration" -o "$docker_dir/kanban_mcp/migrations/$migration"
    done

    echo "Docker files downloaded to $docker_dir"
}

start_docker_mysql() {
    local docker_dir="$CONFIG_DIR/docker"

    echo "Starting MySQL via Docker Compose..."
    docker compose -f "$docker_dir/docker-compose.yml" up -d

    echo "Waiting for MySQL to become healthy..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker compose -f "$docker_dir/docker-compose.yml" ps --format json 2>/dev/null | grep -q '"healthy"'; then
            echo "MySQL is ready."
            return 0
        fi
        # Fallback check for older docker compose versions
        if docker compose -f "$docker_dir/docker-compose.yml" ps 2>/dev/null | grep -q "(healthy)"; then
            echo "MySQL is ready."
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done

    echo "Warning: MySQL healthcheck timed out. It may still be starting."
    echo "Check status with: docker compose -f $docker_dir/docker-compose.yml ps"
}

find_migrations() {
    MIGRATIONS_DIR=""
    if [ -d "./kanban_mcp/migrations" ]; then
        MIGRATIONS_DIR="./kanban_mcp/migrations"
    else
        local pkg_dir
        pkg_dir=$($PYTHON -c "import kanban_mcp; import os; print(os.path.dirname(kanban_mcp.__file__))" 2>/dev/null || true)
        if [ -n "$pkg_dir" ] && [ -d "$pkg_dir/migrations" ]; then
            MIGRATIONS_DIR="$pkg_dir/migrations"
        fi
    fi
}

run_db_setup() {
    local db_host="$1" db_name="$2" db_user="$3" db_password="$4"

    # Check mysql client is available
    if ! command -v mysql &>/dev/null; then
        echo "Error: mysql client not found. Install it first:"
        echo "  Ubuntu/Debian: sudo apt install mysql-client"
        echo "  macOS:         brew install mysql-client"
        echo "  Arch:          sudo pacman -S mariadb-clients"
        exit 1
    fi

    find_migrations
    if [ -z "$MIGRATIONS_DIR" ]; then
        echo "Error: Could not find migration files."
        echo "Ensure kanban-mcp is installed (pipx install kanban-mcp)."
        exit 1
    fi

    echo "Found migrations in: $MIGRATIONS_DIR"
    echo

    # --- Create database and user ---
    echo "--- Creating database and user ---"

    MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"
    local MYSQL_AUTH=(-u "$MYSQL_ROOT_USER" -h "$db_host")
    if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
        MYSQL_AUTH+=(-p"$MYSQL_ROOT_PASSWORD")
    elif [ "$AUTO" = false ]; then
        echo "(You may be prompted for the MySQL root password)"
        MYSQL_AUTH+=(-p)
    fi

    mysql "${MYSQL_AUTH[@]}" <<EOF
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
FLUSH PRIVILEGES;
EOF

    echo "Database and user created."

    # --- Run migrations ---
    echo
    echo "--- Running migrations ---"

    for migration in "$MIGRATIONS_DIR"/0*.sql; do
        echo "  Applying $(basename "$migration")..."
        mysql -u "$db_user" -p"$db_password" -h "$db_host" "$db_name" < "$migration"
    done

    echo "Migrations complete."
}

write_env() {
    local db_host="$1" db_user="$2" db_password="$3" db_name="$4"

    mkdir -p "$CONFIG_DIR"
    local env_file="$CONFIG_DIR/.env"
    local write_it=true

    if [ -f "$env_file" ]; then
        if [ "$AUTO" = true ]; then
            true  # overwrite silently
        else
            read -rp "$env_file already exists. Overwrite? [y/N] " OVERWRITE
            OVERWRITE=${OVERWRITE:-N}
            if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
                echo "Skipping .env generation."
                write_it=false
            fi
        fi
    fi

    if [ "$write_it" = true ]; then
        cat > "$env_file" <<EOF
# kanban-mcp database configuration
KANBAN_DB_HOST=$db_host
KANBAN_DB_USER=$db_user
KANBAN_DB_PASSWORD=$db_password
KANBAN_DB_NAME=$db_name
EOF
        echo "Created $env_file"
    fi
}

print_next_steps() {
    local db_host="$1" db_user="$2" db_password="$3" db_name="$4"

    echo
    echo "=== Setup complete ==="
    echo
    echo "Next steps:"
    echo
    echo "1. Add kanban-mcp to your MCP client config."
    echo
    echo "   Claude Desktop (~/.config/Claude/claude_desktop_config.json):"
    echo '   {'
    echo '     "mcpServers": {'
    echo '       "kanban": {'
    echo '         "command": "kanban-mcp",'
    echo '         "env": {'
    echo "           \"KANBAN_DB_HOST\": \"$db_host\","
    echo "           \"KANBAN_DB_USER\": \"$db_user\","
    echo "           \"KANBAN_DB_PASSWORD\": \"$db_password\","
    echo "           \"KANBAN_DB_NAME\": \"$db_name\""
    echo '         }'
    echo '       }'
    echo '     }'
    echo '   }'
    echo
    echo "2. Start the web UI (optional):"
    echo "   kanban-web"
    echo "   Open http://localhost:5000"
    echo
    echo "3. Verify installation:"
    echo "   kanban-cli --project /path/to/your/project summary"
    echo
}

# ─── Step 1: Python & kanban-mcp ────────────────────────────────────

check_python

if ! command -v kanban-mcp &>/dev/null; then
    echo
    if [ "$AUTO" = true ]; then
        # Auto mode: install without asking
        if ! check_pipx; then
            install_pipx
        fi
        install_kanban_mcp
    else
        echo "kanban-mcp is not installed."
        read -rp "Install kanban-mcp via pipx? [Y/n] " INSTALL_IT
        INSTALL_IT=${INSTALL_IT:-Y}
        if [[ "$INSTALL_IT" =~ ^[Yy] ]]; then
            if ! check_pipx; then
                install_pipx
            fi
            install_kanban_mcp
        else
            echo "Skipping kanban-mcp install. You can install manually with: pipx install kanban-mcp"
        fi
    fi
else
    echo "Found kanban-mcp"
fi

echo

# ─── Step 2: MySQL setup ────────────────────────────────────────────

# Determine MySQL connection method
MYSQL_METHOD=""  # "local", "remote", or "docker"

if [ "$USE_DOCKER" = true ]; then
    MYSQL_METHOD="docker"
elif [ -n "$DB_HOST_ARG" ]; then
    MYSQL_METHOD="remote"
    DB_HOST="$DB_HOST_ARG"
elif [ "$AUTO" = true ]; then
    # Auto mode without --docker or --db-host: assume local MySQL
    MYSQL_METHOD="local"
else
    # Interactive: detect and ask
    echo "How do you want to connect to MySQL?"
    echo "  1) Local MySQL (default)"
    echo "  2) Remote MySQL server"
    echo "  3) Docker (starts MySQL in a container)"
    read -rp "Choice [1]: " MYSQL_CHOICE
    MYSQL_CHOICE=${MYSQL_CHOICE:-1}

    case "$MYSQL_CHOICE" in
        1) MYSQL_METHOD="local" ;;
        2) MYSQL_METHOD="remote" ;;
        3) MYSQL_METHOD="docker" ;;
        *)
            echo "Invalid choice. Using local MySQL."
            MYSQL_METHOD="local"
            ;;
    esac
fi

case "$MYSQL_METHOD" in
    local)
        DB_HOST="${KANBAN_DB_HOST:-localhost}"
        if check_mysql_running "$DB_HOST"; then
            echo "MySQL is running on $DB_HOST."
        else
            echo "MySQL is not running on $DB_HOST."
            if check_docker; then
                if [ "$AUTO" = true ]; then
                    echo "Use --docker flag to start MySQL via Docker."
                    echo "Or start MySQL manually and re-run this script."
                    exit 1
                fi
                read -rp "Start MySQL via Docker? [Y/n] " START_DOCKER
                START_DOCKER=${START_DOCKER:-Y}
                if [[ "$START_DOCKER" =~ ^[Yy] ]]; then
                    MYSQL_METHOD="docker"
                else
                    echo
                    echo "Please start MySQL and re-run this script."
                    echo "  Ubuntu/Debian: sudo systemctl start mysql"
                    echo "  macOS:         brew services start mysql"
                    echo "  Arch:          sudo systemctl start mysqld"
                    exit 1
                fi
            else
                echo
                echo "Docker is not available either. Please install MySQL or Docker:"
                echo "  MySQL: https://dev.mysql.com/downloads/"
                echo "  Docker: https://docs.docker.com/get-docker/"
                exit 1
            fi
        fi
        ;;

    remote)
        if [ -z "$DB_HOST" ]; then
            read -rp "MySQL host: " DB_HOST
        fi
        if [ -z "$DB_HOST" ]; then
            echo "Error: No host provided."
            exit 1
        fi
        local_port="3306"
        if [ "$AUTO" = false ]; then
            read -rp "MySQL port [$local_port]: " DB_PORT_INPUT
            local_port=${DB_PORT_INPUT:-$local_port}
        fi
        echo "Will connect to MySQL at $DB_HOST:$local_port"
        ;;

    docker)
        if ! check_docker; then
            echo "Error: Docker is not installed or docker compose is not available."
            echo "Install Docker: https://docs.docker.com/get-docker/"
            exit 1
        fi
        ;;
esac

echo

# ─── Step 3: Execute the chosen path ────────────────────────────────

if [ "$MYSQL_METHOD" = "docker" ]; then
    # Docker path: download files, start compose, use compose defaults
    DB_NAME="${KANBAN_DB_NAME:-kanban}"
    DB_USER="${KANBAN_DB_USER:-kanban}"
    DB_PASSWORD="${KANBAN_DB_PASSWORD:-changeme}"
    DB_HOST="localhost"

    download_docker_files
    echo

    # Export env vars so docker-compose.yml picks them up
    export KANBAN_DB_NAME="$DB_NAME"
    export KANBAN_DB_USER="$DB_USER"
    export KANBAN_DB_PASSWORD="$DB_PASSWORD"

    start_docker_mysql
    echo

    # Write .env and print instructions — no manual DB setup needed
    # (Docker initdb.d handles schema + migrations automatically)
    write_env "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
    print_next_steps "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"

    echo "Docker compose files: $CONFIG_DIR/docker/"
    echo "Manage with: docker compose -f $CONFIG_DIR/docker/docker-compose.yml [up|down|logs]"
    echo

else
    # Local or remote MySQL: gather creds and run DB setup

    if [ "$AUTO" = true ]; then
        DB_NAME="${KANBAN_DB_NAME:-kanban}"
        DB_USER="${KANBAN_DB_USER:-kanban}"
        DB_HOST="${DB_HOST:-${KANBAN_DB_HOST:-localhost}}"

        if [ -z "${KANBAN_DB_PASSWORD:-}" ]; then
            DB_PASSWORD=$($PYTHON -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || openssl rand -base64 16)
            echo "Generated password: $DB_PASSWORD"
        else
            DB_PASSWORD="$KANBAN_DB_PASSWORD"
        fi
    else
        read -rp "Database name [kanban]: " DB_NAME
        DB_NAME=${DB_NAME:-kanban}

        read -rp "Database user [kanban]: " DB_USER
        DB_USER=${DB_USER:-kanban}

        read -rp "Database password (leave blank to auto-generate): " DB_PASSWORD
        if [ -z "$DB_PASSWORD" ]; then
            DB_PASSWORD=$($PYTHON -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || openssl rand -base64 16)
            echo "Generated password: $DB_PASSWORD"
        fi

        if [ "$MYSQL_METHOD" = "local" ]; then
            DB_HOST="${DB_HOST:-localhost}"
        else
            # Remote — already set from earlier prompt
            true
        fi

        read -rp "MySQL root user for setup [root]: " MYSQL_ROOT_USER_INPUT
        MYSQL_ROOT_USER=${MYSQL_ROOT_USER_INPUT:-${MYSQL_ROOT_USER:-root}}
    fi

    echo
    echo "Configuration:"
    echo "  Database: $DB_NAME"
    echo "  User:     $DB_USER"
    echo "  Host:     $DB_HOST"
    echo

    if [ "$AUTO" = false ]; then
        read -rp "Proceed? [Y/n] " CONFIRM
        CONFIRM=${CONFIRM:-Y}
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    run_db_setup "$DB_HOST" "$DB_NAME" "$DB_USER" "$DB_PASSWORD"

    # Install semantic dependencies if requested
    if [ "$WITH_SEMANTIC" = true ]; then
        echo
        echo "--- Installing semantic search dependencies ---"
        pip install "kanban-mcp[semantic]"
        echo "Semantic search dependencies installed."
    fi

    write_env "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
    print_next_steps "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
fi
