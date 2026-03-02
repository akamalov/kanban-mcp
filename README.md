# kanban-mcp

A database-backed kanban board that AI coding agents use via [MCP](https://modelcontextprotocol.io/) (Model Context Protocol). Track issues, features, todos, epics, and diary entries across all your projects — with a web UI for humans and 40+ tools for agents.

## What It Does

- **Persistent project tracking** — issues, features, todos, epics, diary entries stored in MySQL
- **Status workflows** — each item type has its own progression (backlog → todo → in_progress → review → done → closed)
- **Relationships & epics** — parent/child hierarchies, blocking relationships, epic progress tracking
- **Tags, decisions, file links** — attach metadata to any item
- **Semantic search** — find similar items using local ONNX embeddings (optional)
- **Activity timeline** — unified view of status changes, decisions, updates, and git commits
- **Export** — JSON, YAML, or Markdown output with filters
- **Web UI** — browser-based board at localhost:5000
- **Session hooks** — inject active items into AI agent sessions automatically

## Quick Start

**Linux / macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/multidimensionalcats/kanban-mcp/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/multidimensionalcats/kanban-mcp/main/install.ps1 | iex
```

The install script handles everything: installs pipx and kanban-mcp, detects MySQL (or starts it via Docker), creates the database, runs migrations, and writes your config.

**Already have MySQL running?** The fast path:

```bash
pipx install kanban-mcp[semantic]
kanban-setup
kanban-cli --project . summary
```

## Prerequisites

- **Python 3.10+**
- **MySQL 8.0+** — one of:
  - Local MySQL install
  - Remote MySQL server
  - Docker (the install script can set this up for you)
- **pipx** (recommended) — installed automatically by the install script if missing

## Installation

The install script is the primary install method. It detects your MySQL situation and walks you through setup:

```bash
# Interactive — detects MySQL, offers Docker if needed, installs pipx/kanban-mcp
./install.sh

# Non-interactive with Docker for MySQL
./install.sh --auto --docker

# Non-interactive with remote MySQL
./install.sh --auto --db-host remote.example.com

# Windows equivalents
.\install.ps1
.\install.ps1 -Auto -Docker
.\install.ps1 -Auto -DbHost remote.example.com
```

### Option 1: pipx (recommended)

[pipx](https://pipx.pypa.io/) installs into an isolated virtualenv while making commands globally available. This avoids PEP 668 conflicts on modern distros and ensures hooks work outside the venv.

```bash
pipx install kanban-mcp[semantic]
```

Without semantic search (smaller install):

```bash
pipx install kanban-mcp
```

Upgrade later with:

```bash
pipx upgrade kanban-mcp
```

### Option 2: pip

```bash
pip install --user kanban-mcp[semantic]
```

> **Note:** On modern distros (Debian 12+, Fedora 38+, Arch, Gentoo), bare `pip install` is blocked by [PEP 668](https://peps.python.org/pep-0668/). Use `--user`, `--break-system-packages`, or prefer pipx.

### Option 3: From source (development)

```bash
git clone https://github.com/multidimensionalcats/kanban-mcp.git
cd kanban-mcp
pip install -e .[dev,semantic]
```

> **Note:** If PEP 668 blocks the install, use a venv: `python3 -m venv .venv && source .venv/bin/activate` first. Be aware that hooks run via `/bin/sh`, not the venv Python — you'll need to use full paths to the venv's console scripts in your hook configuration.

### Option 4: Docker (MySQL + web UI)

The install script can start MySQL via Docker for you (`./install.sh --docker` or choose Docker when prompted). If you prefer to run the compose stack manually:

```bash
git clone https://github.com/multidimensionalcats/kanban-mcp.git
cd kanban-mcp
docker compose up
```

This starts MySQL 8.0 and the web UI on port 5000. Migrations run automatically via `initdb.d`. MySQL is exposed on port 3306 so the host-side MCP server can connect. The MCP server still needs a separate install (pipx or pip) since MCP clients spawn it as a subprocess.

Credentials are configurable via environment variables:

```bash
KANBAN_DB_USER=myuser KANBAN_DB_PASSWORD=secret docker compose up
```

## Database Setup

Requires **MySQL 8.0+** running locally (or remotely).

### Automated (interactive)

```bash
kanban-setup
```

Prompts for database name, user, password, and MySQL root credentials, then creates the database, runs migrations, and writes credentials to `~/.config/kanban-mcp/.env`.

> **Note:** `kanban-setup --with-semantic` installs the semantic search Python packages. This is only needed if you installed without `[semantic]` initially (e.g. `pipx install kanban-mcp`). If you already installed with `kanban-mcp[semantic]`, you don't need this flag.

### Automated (non-interactive / AI agents)

The `--auto` flag skips all interactive prompts. Without it, `kanban-setup` will prompt for each value.

```bash
# Minimal — uses socket auth for MySQL root, auto-generates app password
kanban-setup --auto

# With MySQL root password (required if root uses password auth)
kanban-setup --auto --mysql-root-password rootpass

# With explicit credentials via environment variables
KANBAN_DB_NAME=kanban KANBAN_DB_USER=kanban KANBAN_DB_PASSWORD=secret \
  MYSQL_ROOT_PASSWORD=rootpass kanban-setup --auto

# With CLI args
kanban-setup --auto --db-name mydb --db-user myuser --db-password secret
```

> **Note:** If your MySQL root user requires a password (most setups), you must provide `--mysql-root-password` or `MYSQL_ROOT_PASSWORD`. Without it, `kanban-setup --auto` will attempt socket authentication, which fails on most non-local MySQL setups.

### Install script reference

The install scripts can be run from the repo or downloaded standalone:

```bash
./install.sh                          # interactive (detects MySQL, offers Docker)
./install.sh --auto                   # non-interactive, local MySQL
./install.sh --auto --docker          # non-interactive, Docker for MySQL
./install.sh --auto --db-host HOST    # non-interactive, remote MySQL

.\install.ps1                         # Windows interactive
.\install.ps1 -Auto                   # Windows non-interactive
.\install.ps1 -Auto -Docker           # Windows Docker
.\install.ps1 -Auto -DbHost HOST      # Windows remote MySQL
```

| Env Variable | Default | Description |
|---|---|---|
| `KANBAN_DB_NAME` | `kanban` | Database name |
| `KANBAN_DB_USER` | `kanban` | Database user |
| `KANBAN_DB_PASSWORD` | *(auto-generated)* | Database password |
| `KANBAN_DB_HOST` | `localhost` | MySQL host |
| `MYSQL_ROOT_USER` | `root` | MySQL admin user |
| `MYSQL_ROOT_PASSWORD` | *(none — tries socket auth)* | MySQL admin password |

### Manual

```sql
-- As MySQL root user:
CREATE DATABASE kanban CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'kanban'@'%' IDENTIFIED BY 'your_password_here';
GRANT ALL PRIVILEGES ON `kanban`.* TO 'kanban'@'%';
FLUSH PRIVILEGES;
```

Run the migration files in order:

```bash
mysql -u kanban -p kanban < kanban_mcp/migrations/001_initial_schema.sql
mysql -u kanban -p kanban < kanban_mcp/migrations/002_add_fulltext_search.sql
mysql -u kanban -p kanban < kanban_mcp/migrations/003_add_embeddings.sql
mysql -u kanban -p kanban < kanban_mcp/migrations/004_add_cascades_and_indexes.sql
```

## Configuration

### Credentials

`kanban-setup` writes database credentials to a `.env` file in the user config directory:

- **Linux/macOS:** `~/.config/kanban-mcp/.env` (or `$XDG_CONFIG_HOME/kanban-mcp/.env`)
- **Windows:** `%APPDATA%\kanban-mcp\.env`

All install methods (pipx, pip, source) use this same location. You can also set credentials via environment variables or your MCP client's `env` block.

**Precedence** (highest to lowest): MCP client `env` block → shell environment variables → `.env` file. In practice, just use one method — the `.env` file from `kanban-setup` is simplest.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `KANBAN_DB_HOST` | No | `localhost` | MySQL server host |
| `KANBAN_DB_USER` | Yes | — | MySQL username |
| `KANBAN_DB_PASSWORD` | Yes | — | MySQL password |
| `KANBAN_DB_NAME` | Yes | — | MySQL database name |
| `KANBAN_DB_POOL_SIZE` | No | `5` | Connection pool size |
| `KANBAN_PROJECT_DIR` | No | — | Override project directory detection |

### MCP Client Setup

The `kanban-mcp` server speaks JSON-RPC 2.0 over stdin/stdout (standard MCP STDIO transport). Any MCP client can use it. If `kanban-setup` already wrote your `.env` file, you only need the command — no `env` block required.

If you need to pass credentials explicitly (e.g. the client doesn't inherit your shell environment), add an `env` block:

```json
"env": {
  "KANBAN_DB_HOST": "localhost",
  "KANBAN_DB_USER": "kanban",
  "KANBAN_DB_PASSWORD": "your_password_here",
  "KANBAN_DB_NAME": "kanban"
}
```

#### Claude Code

Add to `~/.claude.json` (global) or `.mcp.json` (per-project):

```json
{
  "mcpServers": {
    "kanban": {
      "command": "kanban-mcp"
    }
  }
}
```

#### Claude Desktop

Add to `~/.config/Claude/claude_desktop_config.json` (Linux) or `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

```json
{
  "mcpServers": {
    "kanban": {
      "command": "kanban-mcp"
    }
  }
}
```

#### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "kanban": {
      "command": "kanban-mcp"
    }
  }
}
```

#### VS Code / Copilot

Add to `.vscode/mcp.json` (per-project):

```json
{
  "servers": {
    "kanban": {
      "command": "kanban-mcp"
    }
  }
}
```

> **Note:** VS Code uses the key `servers`, not `mcpServers`.

#### Codex CLI

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.kanban]
command = "kanban-mcp"
```

#### Cursor

Add to `.cursor/mcp.json` (per-project):

```json
{
  "mcpServers": {
    "kanban": {
      "command": "kanban-mcp"
    }
  }
}
```

#### Other MCP Clients

For any other MCP-compatible tool: point it at the `kanban-mcp` command with STDIO transport. If the tool can't read the `.env` file (e.g. it doesn't inherit your shell environment), pass the four `KANBAN_DB_*` variables via the client's env configuration.

### Hooks (Claude Code)

Hooks inject active kanban items at session start and prompt for progress updates at session end. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "kanban-hook-session-start"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "kanban-hook-stop"
          }
        ]
      }
    ]
  }
}
```

> **Important:** Hooks run via `/bin/sh`, which does NOT read your shell profile (`~/.bashrc`, `~/.zshrc`). If `kanban-hook-session-start` isn't found, you need the full path. Find it with `which kanban-hook-session-start` (pipx typically installs to `~/.local/bin/`), then use that absolute path in the `command` field.

**Other tools with hook support:** Cursor, Gemini CLI, and others have their own hook/event mechanisms. The commands are the same (`kanban-hook-session-start` and `kanban-hook-stop`) — adapt the syntax to your tool's configuration format.

## Upgrading

**pipx:**
```bash
pipx upgrade kanban-mcp
```

**pip:**
```bash
pip install --user --upgrade kanban-mcp
```

**From source:**
```bash
cd kanban-mcp && git pull && pip install -e .[dev,semantic]
```

After upgrading, re-run `kanban-setup` if new migrations were added (it's safe to re-run — existing tables are preserved).

## AI Agent Install Guide

Machine-parseable setup instructions for automated installation by AI agents. These steps are client-agnostic — adapt the MCP config file path and format for your specific AI tool (see MCP Client Setup above).

### Quick path (recommended for agents)

If MySQL is running and the root user has socket auth or a known password:

```bash
pipx install kanban-mcp[semantic]
kanban-setup --auto --mysql-root-password rootpass
```

The `--auto` flag skips all prompts. Credentials come from CLI args, env vars, or sensible defaults. The generated `.env` file (at `~/.config/kanban-mcp/.env`) and stdout output contain the credentials needed for MCP config. If your MySQL root user uses socket auth (no password), omit `--mysql-root-password`.

Then add to your MCP client config:

```json
{
  "command": "kanban-mcp"
}
```

The config file location and wrapper key depend on your tool — see MCP Client Setup.

### Manual path (step by step)

#### Step 1: Check prerequisites

```bash
python3 --version   # Requires 3.10+
mysql --version     # Requires MySQL 8.0+
```

#### Step 2: Install kanban-mcp

```bash
pipx install kanban-mcp[semantic]    # with semantic search (recommended)
# OR without semantic search:
pipx install kanban-mcp
```

#### Step 3: Set up the database

```bash
# If MySQL root uses password auth:
kanban-setup --auto --mysql-root-password rootpass

# If MySQL root uses socket auth (no password):
kanban-setup --auto
```

Or manually:

```sql
-- Connect as root: mysql -u root -p
CREATE DATABASE kanban CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'kanban'@'%' IDENTIFIED BY 'GENERATE_A_SECURE_PASSWORD';
GRANT ALL PRIVILEGES ON `kanban`.* TO 'kanban'@'%';
FLUSH PRIVILEGES;
```

```bash
# Run migrations (replace password)
mysql -u kanban -pYOUR_PASSWORD kanban < "$(python3 -c 'import kanban_mcp, os; print(os.path.dirname(kanban_mcp.__file__))')/migrations/001_initial_schema.sql"
mysql -u kanban -pYOUR_PASSWORD kanban < "$(python3 -c 'import kanban_mcp, os; print(os.path.dirname(kanban_mcp.__file__))')/migrations/002_add_fulltext_search.sql"
mysql -u kanban -pYOUR_PASSWORD kanban < "$(python3 -c 'import kanban_mcp, os; print(os.path.dirname(kanban_mcp.__file__))')/migrations/003_add_embeddings.sql"
mysql -u kanban -pYOUR_PASSWORD kanban < "$(python3 -c 'import kanban_mcp, os; print(os.path.dirname(kanban_mcp.__file__))')/migrations/004_add_cascades_and_indexes.sql"
```

#### Step 4: MCP config

Add kanban-mcp to your AI tool's MCP configuration. The server entry is:

```json
{
  "kanban": {
    "command": "kanban-mcp"
  }
}
```

| Tool | Config file | Wrapper key |
|------|-------------|-------------|
| Claude Code | `~/.claude.json` or `.mcp.json` | `mcpServers` |
| Claude Desktop | `~/.config/Claude/claude_desktop_config.json` | `mcpServers` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers` |
| VS Code / Copilot | `.vscode/mcp.json` | `servers` |
| Codex CLI | `~/.codex/config.toml` | `[mcp_servers.kanban]` |
| Cursor | `.cursor/mcp.json` | `mcpServers` |

If the tool can't read the `.env` file, add the `env` block with the four `KANBAN_DB_*` variables (see Configuration > Credentials).

#### Step 5: Hooks setup (optional, Claude Code)

Find the full path to the hook commands (hooks run via `/bin/sh`, not your shell profile):

```bash
which kanban-hook-session-start   # e.g. /home/user/.local/bin/kanban-hook-session-start
which kanban-hook-stop            # e.g. /home/user/.local/bin/kanban-hook-stop
```

Add to `~/.claude/settings.json`, using the full paths from above:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/user/.local/bin/kanban-hook-session-start"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/user/.local/bin/kanban-hook-stop"
          }
        ]
      }
    ]
  }
}
```

#### Step 6: Verify installation

```bash
kanban-cli --project /path/to/your/project summary
```

Expected output (for a new/empty project):

```
No items found for this project.
```

For a project with existing items, you'll see a table of item counts grouped by type and status.

## Entry Points

| Command | Description |
|---------|-------------|
| `kanban-mcp` | MCP server (STDIO JSON-RPC) — used by AI clients |
| `kanban-web` | Web UI on localhost:5000 (`--port`, `--host`, `--debug` flags) |
| `kanban-cli` | CLI for manual queries and hook scripts (`--project`, `--format` flags) |
| `kanban-setup` | Database setup wizard (`--auto` for non-interactive, `--with-semantic`) |
| `kanban-hook-session-start` | Session start hook — injects active items into agent sessions |
| `kanban-hook-stop` | Session stop hook — prompts for progress updates |

## MCP Tools Reference

### Project Management

| Tool | Description |
|------|-------------|
| `set_current_project` | Set the current project context (called at session start with $PWD) |
| `get_current_project` | Get the current project context |
| `project_summary` | Get summary of items by type and status |
| `get_active_items` | Get items in 'in_progress' status |
| `get_todos` | Get items in 'backlog' status — the todo queue |

### Item CRUD

| Tool | Description |
|------|-------------|
| `new_item` | Create a new issue, todo, feature, epic, or diary entry |
| `list_items` | List items with optional type/status/tag filters |
| `get_item` | Get full details of a specific item |
| `edit_item` | Edit an item's title, description, priority, complexity, and/or parent |
| `delete_item` | Permanently delete an item |

### Status Workflow

| Tool | Description |
|------|-------------|
| `advance_status` | Move item to next status in its workflow |
| `revert_status` | Move item to previous status |
| `set_status` | Set item to a specific status |
| `close_item` | Mark item as done/closed |
| `get_status_history` | Get status change history for an item |
| `get_item_metrics` | Get calculated metrics: lead_time, cycle_time, time_in_each_status |

### Progress Updates

| Tool | Description |
|------|-------------|
| `add_update` | Add a progress update, optionally linked to items |
| `get_latest_update` | Get the most recent update |
| `get_updates` | Get recent updates |

### Relationships & Hierarchy

| Tool | Description |
|------|-------------|
| `add_relationship` | Add a relationship (blocks, depends_on, relates_to, duplicates) |
| `remove_relationship` | Remove a relationship |
| `get_item_relationships` | Get all relationships for an item |
| `get_blocking_items` | Get items that block a given item |
| `set_parent` | Set or remove parent relationship |
| `list_children` | Get children of an item (optional recursive) |
| `get_epic_progress` | Get progress stats for an epic |

### Tags

| Tool | Description |
|------|-------------|
| `list_tags` | List all tags with usage counts |
| `add_tag` | Add a tag to an item |
| `remove_tag` | Remove a tag from an item |
| `get_item_tags` | Get all tags assigned to an item |
| `update_tag` | Update tag name and/or color |
| `delete_tag` | Delete a tag from the project |

### File Links & Decisions

| Tool | Description |
|------|-------------|
| `link_file` | Link a file (or file region) to an item |
| `unlink_file` | Remove a file link |
| `get_item_files` | Get all files linked to an item |
| `add_decision` | Add a decision record to an item |
| `get_item_decisions` | Get all decisions for an item |
| `delete_decision` | Delete a decision record |

### Search & Export

| Tool | Description |
|------|-------------|
| `search` | Full-text search across items and updates |
| `semantic_search` | Search by semantic similarity (requires `[semantic]` extra) |
| `find_similar` | Find items similar to a given item, decision, or update |
| `rebuild_embeddings` | Rebuild all embeddings for the project |
| `export_project` | Export project data in JSON, YAML, or Markdown |

### Timeline

| Tool | Description |
|------|-------------|
| `get_item_timeline` | Activity timeline for a specific item |
| `get_project_timeline` | Activity timeline for the entire project |

## Item Types & Workflows

| Type | Workflow |
|------|----------|
| issue | backlog → todo → in_progress → review → done → closed |
| feature | backlog → todo → in_progress → review → done → closed |
| epic | backlog → todo → in_progress → review → done → closed |
| todo | backlog → todo → in_progress → done |
| question | backlog → in_progress → done |
| diary | done (single state) |

## Contributing

```bash
git clone https://github.com/multidimensionalcats/kanban-mcp.git
cd kanban-mcp
python3 -m venv .venv && source .venv/bin/activate
pip install -e .[dev,semantic]

# Run Python tests (requires MySQL with test DB configured)
pytest

# Run frontend JS tests (requires Node.js — optional, only touches web UI code)
npm install && npm test
```

## License

[MIT](LICENSE)
