#!/bin/bash
# Deploy kanban-mcp to ~/kanban_mcp/
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HOME/kanban_mcp"

# Python 3.13 required for onnxruntime (semantic search)
PYTHON="/usr/bin/python3.13"
if [[ ! -x "$PYTHON" ]]; then
    echo "WARNING: $PYTHON not found, falling back to python3"
    PYTHON="python3"
fi

echo "=== Deploying kanban-mcp ==="
echo "Source: $SRC_DIR"
echo "Destination: $DEST_DIR"
echo "Python: $PYTHON"

# Create destination
mkdir -p "$DEST_DIR/hooks" "$DEST_DIR/templates" "$DEST_DIR/static" "$DEST_DIR/migrations"

# Rsync executables and web UI
rsync -av --delete \
    --include='kanban_mcp.py' \
    --include='kanban_cli.py' \
    --include='kanban_web.py' \
    --include='kanban_export.py' \
    --include='git_timeline.py' \
    --include='timeline_builder.py' \
    --include='hooks/' \
    --include='hooks/*.py' \
    --include='templates/' \
    --include='templates/*.html' \
    --include='static/' \
    --include='static/*.css' \
    --include='static/*.js' \
    --include='migrations/' \
    --include='migrations/*.sql' \
    --include='.env.example' \
    --include='Dockerfile' \
    --include='docker-compose.yml' \
    --include='.dockerignore' \
    --exclude='*' \
    "$SRC_DIR/" "$DEST_DIR/"

# Set up .env config
if [[ -f "$DEST_DIR/.env" ]]; then
    echo "Existing .env preserved at $DEST_DIR/.env"
elif [[ -f "$SRC_DIR/.env" ]]; then
    cp "$SRC_DIR/.env" "$DEST_DIR/.env"
    echo "Copied .env from source to $DEST_DIR"
else
    cp "$DEST_DIR/.env.example" "$DEST_DIR/.env"
    echo "Created .env from .env.example at $DEST_DIR — edit with your credentials"
fi

echo ""
echo "Files deployed:"
ls -la "$DEST_DIR"
ls -la "$DEST_DIR/hooks"
ls -la "$DEST_DIR/templates"
ls -la "$DEST_DIR/static"

# --- Docker setup ---
echo ""
echo "=== Docker Setup ==="
if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    echo "Docker detected."
    if docker compose -f "$DEST_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q 'db'; then
        echo "Docker services already running."
    else
        echo "Start MySQL + web UI with:"
        echo "  cd $DEST_DIR && docker compose up -d"
    fi
    echo ""
    echo "Docker commands:"
    echo "  docker compose -f $DEST_DIR/docker-compose.yml up -d      # start"
    echo "  docker compose -f $DEST_DIR/docker-compose.yml down        # stop"
    echo "  docker compose -f $DEST_DIR/docker-compose.yml logs -f     # logs"
else
    echo "Docker not found. Install Docker to use the containerized setup."
    echo "Without Docker, you need a MySQL server running locally."
fi

# --- Claude Code hooks (central) ---
CLAUDE_CODE_SETTINGS="$HOME/.claude/settings.json"
echo ""
echo "=== Claude Code hooks ==="
mkdir -p "$HOME/.claude"

if [[ -f "$CLAUDE_CODE_SETTINGS" ]]; then
    if grep -q 'kanban_mcp' "$CLAUDE_CODE_SETTINGS" 2>/dev/null; then
        echo "Hooks already configured in $CLAUDE_CODE_SETTINGS"
    else
        echo "Adding hooks to Claude Code settings..."
        if command -v jq &>/dev/null; then
            tmp=$(mktemp)
            jq --arg cmd1 "$PYTHON $DEST_DIR/hooks/session_start.py" \
               --arg cmd2 "$PYTHON $DEST_DIR/hooks/stop.py" \
               '.hooks.SessionStart = (.hooks.SessionStart // []) + [{
                "type": "command",
                "command": $cmd1
            }] | .hooks.Stop = (.hooks.Stop // []) + [{
                "type": "command",
                "command": $cmd2
            }]' "$CLAUDE_CODE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_CODE_SETTINGS"
            echo "Added hooks to Claude Code settings"
        else
            echo "WARNING: jq not installed, cannot auto-configure hooks"
        fi
    fi
else
    echo "Creating $CLAUDE_CODE_SETTINGS with hooks..."
    cat > "$CLAUDE_CODE_SETTINGS" << EOF
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "$PYTHON $DEST_DIR/hooks/session_start.py"
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "$PYTHON $DEST_DIR/hooks/stop.py"
      }
    ]
  }
}
EOF
    echo "Created $CLAUDE_CODE_SETTINGS"
fi

# --- MCP client configuration snippets ---
echo ""
echo "========================================"
echo "=== MCP Client Configuration ==="
echo "========================================"
echo ""
echo "Add kanban-mcp to your MCP client(s) below."
echo "The MCP server runs natively (not in Docker) since MCP clients spawn it as a subprocess."
echo ""

MCP_CMD="$PYTHON"
MCP_ARG="$DEST_DIR/kanban_mcp.py"

# JSON snippet used by most clients
json_snippet() {
    local key="$1"
    cat <<SNIPPET
{
  "$key": {
    "kanban": {
      "command": "$MCP_CMD",
      "args": ["$MCP_ARG"],
      "env": {
        "KANBAN_DB_HOST": "localhost",
        "KANBAN_DB_USER": "kanban",
        "KANBAN_DB_PASSWORD": "changeme",
        "KANBAN_DB_NAME": "kanban"
      }
    }
  }
}
SNIPPET
}

# --- Claude Desktop ---
CLAUDE_DESKTOP_CONFIG="$HOME/.config/Claude/claude_desktop_config.json"
if [[ -d "$HOME/.config/Claude" ]] || [[ -f "$CLAUDE_DESKTOP_CONFIG" ]]; then
    echo "--- Claude Desktop ---"
    echo "File: $CLAUDE_DESKTOP_CONFIG"
    echo ""
    json_snippet "mcpServers"
    echo ""
fi

# --- Claude Code ---
CLAUDE_CODE_CONFIG="$HOME/.claude.json"
if [[ -f "$CLAUDE_CODE_CONFIG" ]] || command -v claude &>/dev/null; then
    echo "--- Claude Code ---"
    echo "File: $CLAUDE_CODE_CONFIG"
    echo ""
    json_snippet "mcpServers"
    echo ""
fi

# --- Gemini CLI ---
GEMINI_CONFIG="$HOME/.gemini/settings.json"
if [[ -d "$HOME/.gemini" ]] || command -v gemini &>/dev/null; then
    echo "--- Gemini CLI ---"
    echo "File: $GEMINI_CONFIG"
    echo ""
    json_snippet "mcpServers"
    echo ""
fi

# --- VS Code / Copilot ---
if command -v code &>/dev/null || command -v codium &>/dev/null; then
    echo "--- VS Code / Copilot ---"
    echo "File: .vscode/mcp.json (per-project)"
    echo ""
    json_snippet "servers"
    echo ""
fi

# --- Codex CLI ---
CODEX_CONFIG="$HOME/.codex/config.toml"
if [[ -d "$HOME/.codex" ]] || command -v codex &>/dev/null; then
    echo "--- Codex CLI ---"
    echo "File: $CODEX_CONFIG"
    echo ""
    cat <<SNIPPET
[mcp_servers.kanban]
command = "$MCP_CMD"
args = ["$MCP_ARG"]

[mcp_servers.kanban.env]
KANBAN_DB_HOST = "localhost"
KANBAN_DB_USER = "kanban"
KANBAN_DB_PASSWORD = "changeme"
KANBAN_DB_NAME = "kanban"
SNIPPET
    echo ""
fi

# --- LM Studio ---
LMSTUDIO_CONFIG="$HOME/.lmstudio/mcp.json"
if [[ -d "$HOME/.lmstudio" ]]; then
    echo "--- LM Studio ---"
    echo "File: $LMSTUDIO_CONFIG"
    echo ""
    json_snippet "mcpServers"
    echo ""
fi

# --- Cherry Studio ---
if command -v cherry-studio &>/dev/null || [[ -d "$HOME/.config/cherry-studio" ]]; then
    echo "--- Cherry Studio ---"
    echo "Add manually in Cherry Studio MCP settings:"
    echo "  Command: $MCP_CMD"
    echo "  Args:    $MCP_ARG"
    echo "  Env:     KANBAN_DB_HOST=localhost KANBAN_DB_USER=kanban KANBAN_DB_PASSWORD=changeme KANBAN_DB_NAME=kanban"
    echo ""
fi

echo "========================================"
echo ""
echo "=== Deployment complete ==="
echo ""
echo "Quick start:"
echo "  1. cd $DEST_DIR && docker compose up -d"
echo "  2. Add the MCP snippet above to your client config"
echo "  3. Visit http://localhost:5000 for the web UI"
echo ""
echo "Note: For per-project env var config, add .mcp.json to project with:"
echo '  "env": { "KANBAN_PROJECT_DIR": "${CLAUDE_PROJECT_DIR}" }'
