#
# kanban-mcp install script (Windows PowerShell)
# Installs kanban-mcp (via pipx), sets up MySQL (local, remote, or Docker),
# and writes the .env config file.
#
# Interactive (default):
#   .\install.ps1
#   irm https://raw.githubusercontent.com/.../install.ps1 | iex
#
# Non-interactive:
#   .\install.ps1 -Auto                           # local MySQL
#   .\install.ps1 -Auto -Docker                   # MySQL via Docker
#   .\install.ps1 -Auto -DbHost remote.host       # remote MySQL
#
# Options:
#   -Auto            Non-interactive mode (no prompts)
#   -Docker          Use Docker for MySQL (starts docker compose stack)
#   -DbHost HOST     MySQL host (default: localhost)
#   -WithSemantic    Also install semantic search dependencies
#

param(
    [switch]$Auto,
    [switch]$Docker,
    [string]$DbHost = "",
    [switch]$WithSemantic
)

$ErrorActionPreference = "Stop"

$GithubRaw = "https://raw.githubusercontent.com/multidimensionalcats/kanban-mcp/main"
$ConfigDir = if ($env:APPDATA) { Join-Path $env:APPDATA "kanban-mcp" } else { Join-Path $HOME ".config/kanban-mcp" }

Write-Host "=== kanban-mcp Install ===" -ForegroundColor Cyan
Write-Host ""

# ─── Helper functions ───────────────────────────────────────────────

function Test-Python {
    $script:Python = $null
    if (Get-Command "python3" -ErrorAction SilentlyContinue) {
        $script:Python = "python3"
    } elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $script:Python = "python"
    } else {
        Write-Host "Error: Python 3.10+ is required but not found." -ForegroundColor Red
        Write-Host "Install Python from https://www.python.org/downloads/"
        exit 1
    }

    $ver = & $script:Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    $parts = $ver -split '\.'
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
        Write-Host "Error: Python 3.10+ is required (found $ver)." -ForegroundColor Red
        exit 1
    }
    Write-Host "Found Python $ver"
}

function Test-Pipx {
    if (Get-Command "pipx" -ErrorAction SilentlyContinue) {
        Write-Host "Found pipx"
        return $true
    }
    return $false
}

function Install-Pipx {
    Write-Host "Installing pipx..."
    try {
        & $script:Python -m pip install --user pipx 2>$null
    } catch {
        try {
            & $script:Python -m pip install pipx 2>$null
        } catch {
            Write-Host "Error: Could not install pipx. Install it manually:" -ForegroundColor Red
            Write-Host "  https://pipx.pypa.io/stable/installation/"
            exit 1
        }
    }
    try { & $script:Python -m pipx ensurepath 2>$null } catch {}
    if (-not (Get-Command "pipx" -ErrorAction SilentlyContinue)) {
        Write-Host "pipx installed but not in PATH. You may need to restart your shell."
    }
}

function Install-KanbanMcp {
    $pkg = "kanban-mcp"
    if ($WithSemantic) { $pkg = "kanban-mcp[semantic]" }
    Write-Host "Installing $pkg via pipx..."
    if (Get-Command "pipx" -ErrorAction SilentlyContinue) {
        pipx install $pkg
    } else {
        & $script:Python -m pipx install $pkg
    }
    Write-Host "kanban-mcp installed."
}

function Test-MysqlRunning {
    param([string]$Host_ = "localhost", [int]$Port = 3306)
    # Try TCP connection
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($Host_, $Port)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

function Test-DockerAvailable {
    try {
        $null = Get-Command "docker" -ErrorAction Stop
        docker compose version 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-DockerFiles {
    $dockerDir = Join-Path $ConfigDir "docker"
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null

    Write-Host "Downloading Docker files..."
    Invoke-WebRequest -Uri "$GithubRaw/docker-compose.yml" -OutFile (Join-Path $dockerDir "docker-compose.yml")
    Invoke-WebRequest -Uri "$GithubRaw/Dockerfile" -OutFile (Join-Path $dockerDir "Dockerfile")
    Invoke-WebRequest -Uri "$GithubRaw/pyproject.toml" -OutFile (Join-Path $dockerDir "pyproject.toml")

    # Download migrations
    $migrationsDir = Join-Path $dockerDir "kanban_mcp/migrations"
    New-Item -ItemType Directory -Path $migrationsDir -Force | Out-Null
    Invoke-WebRequest -Uri "$GithubRaw/kanban_mcp/__init__.py" -OutFile (Join-Path $dockerDir "kanban_mcp/__init__.py")
    foreach ($migration in @("001_initial_schema.sql", "002_add_fulltext_search.sql", "003_add_embeddings.sql", "004_add_cascades_and_indexes.sql")) {
        Invoke-WebRequest -Uri "$GithubRaw/kanban_mcp/migrations/$migration" -OutFile (Join-Path $migrationsDir $migration)
    }

    Write-Host "Docker files downloaded to $dockerDir"
    return $dockerDir
}

function Start-DockerMysql {
    param([string]$DockerDir)

    Write-Host "Starting MySQL via Docker Compose..."
    docker compose -f (Join-Path $DockerDir "docker-compose.yml") up -d

    Write-Host "Waiting for MySQL to become healthy..."
    $retries = 30
    while ($retries -gt 0) {
        $ps = docker compose -f (Join-Path $DockerDir "docker-compose.yml") ps 2>$null
        if ($ps -match "\(healthy\)") {
            Write-Host "MySQL is ready."
            return
        }
        $retries--
        Start-Sleep -Seconds 2
    }

    Write-Host "Warning: MySQL healthcheck timed out. It may still be starting." -ForegroundColor Yellow
    Write-Host "Check status with: docker compose -f $(Join-Path $DockerDir 'docker-compose.yml') ps"
}

function Find-Migrations {
    if (Test-Path ".\kanban_mcp\migrations") {
        return ".\kanban_mcp\migrations"
    }
    try {
        $pkgDir = & $script:Python -c "import kanban_mcp; import os; print(os.path.dirname(kanban_mcp.__file__))" 2>$null
        if ($pkgDir -and (Test-Path "$pkgDir\migrations")) {
            return "$pkgDir\migrations"
        }
    } catch {}
    return $null
}

function Invoke-DbSetup {
    param([string]$Host_, [string]$Name, [string]$User, [string]$Password)

    if (-not (Get-Command "mysql" -ErrorAction SilentlyContinue)) {
        Write-Host "Error: mysql client not found." -ForegroundColor Red
        Write-Host "Install MySQL and ensure mysql.exe is in your PATH."
        Write-Host "Download: https://dev.mysql.com/downloads/mysql/"
        exit 1
    }

    $migrationsDir = Find-Migrations
    if (-not $migrationsDir) {
        Write-Host "Error: Could not find migration files." -ForegroundColor Red
        Write-Host "Ensure kanban-mcp is installed (pipx install kanban-mcp)."
        exit 1
    }

    Write-Host "Found migrations in: $migrationsDir"
    Write-Host ""

    # --- Create database and user ---
    Write-Host "--- Creating database and user ---"

    $MysqlRootUser = if ($env:MYSQL_ROOT_USER) { $env:MYSQL_ROOT_USER } else { "root" }
    $MysqlRootPassword = $env:MYSQL_ROOT_PASSWORD

    $SetupSql = @"
CREATE DATABASE IF NOT EXISTS ``$Name`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$User'@'%' IDENTIFIED BY '$Password';
GRANT ALL PRIVILEGES ON ``$Name``.* TO '$User'@'%';
FLUSH PRIVILEGES;
"@

    if ($MysqlRootPassword) {
        $SetupSql | mysql -u $MysqlRootUser -p"$MysqlRootPassword" -h $Host_
    } elseif (-not $Auto) {
        Write-Host "(You may be prompted for the MySQL root password)"
        $SetupSql | mysql -u $MysqlRootUser -p -h $Host_
    } else {
        $SetupSql | mysql -u $MysqlRootUser -h $Host_
    }

    Write-Host "Database and user created."

    # --- Run migrations ---
    Write-Host ""
    Write-Host "--- Running migrations ---"

    Get-ChildItem "$migrationsDir\0*.sql" | Sort-Object Name | ForEach-Object {
        Write-Host "  Applying $($_.Name)..."
        Get-Content $_.FullName -Raw | mysql -u $User -p"$Password" -h $Host_ $Name
    }

    Write-Host "Migrations complete."
}

function Write-EnvFile {
    param([string]$Host_, [string]$User, [string]$Password, [string]$Name)

    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    $envFile = Join-Path $ConfigDir ".env"
    $writeIt = $true

    if (Test-Path $envFile) {
        if ($Auto) {
            # overwrite silently
        } else {
            $overwrite = Read-Host "$envFile already exists. Overwrite? [y/N]"
            if (-not $overwrite) { $overwrite = "N" }
            if ($overwrite -notmatch "^[Yy]") {
                Write-Host "Skipping .env generation."
                $writeIt = $false
            }
        }
    }

    if ($writeIt) {
        @"
# kanban-mcp database configuration
KANBAN_DB_HOST=$Host_
KANBAN_DB_USER=$User
KANBAN_DB_PASSWORD=$Password
KANBAN_DB_NAME=$Name
"@ | Set-Content -Path $envFile -Encoding UTF8
        Write-Host "Created $envFile"
    }
}

function Write-NextSteps {
    param([string]$Host_, [string]$User, [string]$Password, [string]$Name)

    Write-Host ""
    Write-Host "=== Setup complete ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host ""
    Write-Host "1. Add kanban-mcp to your MCP client config."
    Write-Host ""
    Write-Host "   Claude Desktop config:"
    Write-Host @"
   {
     "mcpServers": {
       "kanban": {
         "command": "kanban-mcp",
         "env": {
           "KANBAN_DB_HOST": "$Host_",
           "KANBAN_DB_USER": "$User",
           "KANBAN_DB_PASSWORD": "$Password",
           "KANBAN_DB_NAME": "$Name"
         }
       }
     }
   }
"@
    Write-Host ""
    Write-Host "2. Start the web UI (optional):"
    Write-Host "   kanban-web"
    Write-Host "   Open http://localhost:5000"
    Write-Host ""
    Write-Host "3. Verify installation:"
    Write-Host "   kanban-cli --project C:\path\to\your\project summary"
    Write-Host ""
}

# ─── Step 1: Python & kanban-mcp ────────────────────────────────────

Test-Python

if (-not (Get-Command "kanban-mcp" -ErrorAction SilentlyContinue)) {
    Write-Host ""
    if ($Auto) {
        if (-not (Test-Pipx)) { Install-Pipx }
        Install-KanbanMcp
    } else {
        Write-Host "kanban-mcp is not installed."
        $installIt = Read-Host "Install kanban-mcp via pipx? [Y/n]"
        if (-not $installIt) { $installIt = "Y" }
        if ($installIt -match "^[Yy]") {
            if (-not (Test-Pipx)) { Install-Pipx }
            Install-KanbanMcp
        } else {
            Write-Host "Skipping kanban-mcp install. You can install manually with: pipx install kanban-mcp"
        }
    }
} else {
    Write-Host "Found kanban-mcp"
}

Write-Host ""

# ─── Step 2: MySQL setup ────────────────────────────────────────────

$MysqlMethod = ""  # "local", "remote", or "docker"

if ($Docker) {
    $MysqlMethod = "docker"
} elseif ($DbHost) {
    $MysqlMethod = "remote"
} elseif ($Auto) {
    $MysqlMethod = "local"
} else {
    Write-Host "How do you want to connect to MySQL?"
    Write-Host "  1) Local MySQL (default)"
    Write-Host "  2) Remote MySQL server"
    Write-Host "  3) Docker (starts MySQL in a container)"
    $choice = Read-Host "Choice [1]"
    if (-not $choice) { $choice = "1" }

    switch ($choice) {
        "1" { $MysqlMethod = "local" }
        "2" { $MysqlMethod = "remote" }
        "3" { $MysqlMethod = "docker" }
        default {
            Write-Host "Invalid choice. Using local MySQL."
            $MysqlMethod = "local"
        }
    }
}

switch ($MysqlMethod) {
    "local" {
        if (-not $DbHost) { $DbHost = if ($env:KANBAN_DB_HOST) { $env:KANBAN_DB_HOST } else { "localhost" } }
        if (Test-MysqlRunning -Host_ $DbHost) {
            Write-Host "MySQL is running on $DbHost."
        } else {
            Write-Host "MySQL is not running on $DbHost."
            if (Test-DockerAvailable) {
                if ($Auto) {
                    Write-Host "Use -Docker flag to start MySQL via Docker."
                    Write-Host "Or start MySQL manually and re-run this script."
                    exit 1
                }
                $startDocker = Read-Host "Start MySQL via Docker? [Y/n]"
                if (-not $startDocker) { $startDocker = "Y" }
                if ($startDocker -match "^[Yy]") {
                    $MysqlMethod = "docker"
                } else {
                    Write-Host ""
                    Write-Host "Please start MySQL and re-run this script."
                    exit 1
                }
            } else {
                Write-Host ""
                Write-Host "Docker is not available either. Please install MySQL or Docker:"
                Write-Host "  MySQL: https://dev.mysql.com/downloads/"
                Write-Host "  Docker: https://docs.docker.com/get-docker/"
                exit 1
            }
        }
    }
    "remote" {
        if (-not $DbHost) {
            $DbHost = Read-Host "MySQL host"
        }
        if (-not $DbHost) {
            Write-Host "Error: No host provided." -ForegroundColor Red
            exit 1
        }
        Write-Host "Will connect to MySQL at $DbHost"
    }
    "docker" {
        if (-not (Test-DockerAvailable)) {
            Write-Host "Error: Docker is not installed or docker compose is not available." -ForegroundColor Red
            Write-Host "Install Docker: https://docs.docker.com/get-docker/"
            exit 1
        }
    }
}

Write-Host ""

# ─── Step 3: Execute the chosen path ────────────────────────────────

if ($MysqlMethod -eq "docker") {
    $dbName = if ($env:KANBAN_DB_NAME) { $env:KANBAN_DB_NAME } else { "kanban" }
    $dbUser = if ($env:KANBAN_DB_USER) { $env:KANBAN_DB_USER } else { "kanban" }
    $dbPassword = if ($env:KANBAN_DB_PASSWORD) { $env:KANBAN_DB_PASSWORD } else { "changeme" }
    $DbHost = "localhost"

    $dockerDir = Get-DockerFiles
    Write-Host ""

    # Set env vars for docker-compose.yml
    $env:KANBAN_DB_NAME = $dbName
    $env:KANBAN_DB_USER = $dbUser
    $env:KANBAN_DB_PASSWORD = $dbPassword

    Start-DockerMysql -DockerDir $dockerDir
    Write-Host ""

    Write-EnvFile -Host_ $DbHost -User $dbUser -Password $dbPassword -Name $dbName
    Write-NextSteps -Host_ $DbHost -User $dbUser -Password $dbPassword -Name $dbName

    Write-Host "Docker compose files: $dockerDir"
    Write-Host "Manage with: docker compose -f $(Join-Path $dockerDir 'docker-compose.yml') [up|down|logs]"
    Write-Host ""

} else {
    # Local or remote: gather creds and run DB setup

    if ($Auto) {
        $dbName = if ($env:KANBAN_DB_NAME) { $env:KANBAN_DB_NAME } else { "kanban" }
        $dbUser = if ($env:KANBAN_DB_USER) { $env:KANBAN_DB_USER } else { "kanban" }
        if (-not $DbHost) { $DbHost = if ($env:KANBAN_DB_HOST) { $env:KANBAN_DB_HOST } else { "localhost" } }

        if ($env:KANBAN_DB_PASSWORD) {
            $dbPassword = $env:KANBAN_DB_PASSWORD
        } else {
            $dbPassword = & $script:Python -c "import secrets; print(secrets.token_urlsafe(16))"
            Write-Host "Generated password: $dbPassword"
        }
    } else {
        $dbName = Read-Host "Database name [kanban]"
        if (-not $dbName) { $dbName = "kanban" }

        $dbUser = Read-Host "Database user [kanban]"
        if (-not $dbUser) { $dbUser = "kanban" }

        $dbPassword = Read-Host "Database password (leave blank to auto-generate)"
        if (-not $dbPassword) {
            $dbPassword = & $script:Python -c "import secrets; print(secrets.token_urlsafe(16))"
            Write-Host "Generated password: $dbPassword"
        }

        if ($MysqlMethod -eq "local" -and -not $DbHost) {
            $DbHost = "localhost"
        }

        $rootUserInput = Read-Host "MySQL root user for setup [root]"
        if ($rootUserInput) { $env:MYSQL_ROOT_USER = $rootUserInput }
    }

    Write-Host ""
    Write-Host "Configuration:"
    Write-Host "  Database: $dbName"
    Write-Host "  User:     $dbUser"
    Write-Host "  Host:     $DbHost"
    Write-Host ""

    if (-not $Auto) {
        $confirm = Read-Host "Proceed? [Y/n]"
        if (-not $confirm) { $confirm = "Y" }
        if ($confirm -notmatch "^[Yy]") {
            Write-Host "Aborted."
            exit 0
        }
    }

    Invoke-DbSetup -Host_ $DbHost -Name $dbName -User $dbUser -Password $dbPassword

    if ($WithSemantic) {
        Write-Host ""
        Write-Host "--- Installing semantic search dependencies ---"
        pip install "kanban-mcp[semantic]"
        Write-Host "Semantic search dependencies installed."
    }

    Write-EnvFile -Host_ $DbHost -User $dbUser -Password $dbPassword -Name $dbName
    Write-NextSteps -Host_ $DbHost -User $dbUser -Password $dbPassword -Name $dbName
}
