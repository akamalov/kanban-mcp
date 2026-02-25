# Kanban MCP Server - Deployment

## Installation

1. Run the deploy script:
   ```bash
   ./deploy.sh
   ```
   This copies to `~/kanban_mcp/`:
   - `kanban_mcp.py` - MCP server
   - `kanban_cli.py` - CLI tool
   - `kanban_web.py` - Web UI
   - `hooks/` - Session hooks
   - `templates/` - HTML templates
   - `static/` - CSS and JS

2. Ensure MySQL database exists with correct schema (see schema.sql)

3. If upgrading, run the epic support migration:
   ```sql
   -- Add parent_id column for hierarchy
   ALTER TABLE items ADD COLUMN parent_id INT NULL;
   ALTER TABLE items ADD CONSTRAINT fk_items_parent
     FOREIGN KEY (parent_id) REFERENCES items(id) ON DELETE CASCADE;
   CREATE INDEX idx_items_parent_id ON items(parent_id);

   -- Add epic item type
   INSERT IGNORE INTO item_types (name) VALUES ('epic');

   -- Define epic workflow
   INSERT INTO type_status_workflow (type_id, status_id, sequence)
   SELECT
     (SELECT id FROM item_types WHERE name = 'epic'),
     s.id,
     CASE s.name
       WHEN 'backlog' THEN 1 WHEN 'todo' THEN 2 WHEN 'in_progress' THEN 3
       WHEN 'review' THEN 4 WHEN 'done' THEN 5 WHEN 'closed' THEN 6
     END
   FROM statuses s
   WHERE s.name IN ('backlog', 'todo', 'in_progress', 'review', 'done', 'closed')
   ON DUPLICATE KEY UPDATE sequence=VALUES(sequence);

   -- Add auto_advance to change_type enum
   ALTER TABLE status_history MODIFY COLUMN change_type
     ENUM('create','advance','revert','set','close','auto_advance') NOT NULL;
   ```

4. Install Python dependencies:
   ```bash
   pip install mysql-connector-python flask
   ```

## Per-Project Configuration

For each project you want to track, create these files:

### `.mcp.json` (MCP server config)
```json
{
  "mcpServers": {
    "kanban": {
      "command": "python3",
      "args": ["${HOME}/.claude/kanban-mcp/kanban_mcp.py"],
      "env": {
        "KANBAN_PROJECT_DIR": "${CLAUDE_PROJECT_DIR}"
      }
    }
  }
}
```

### `.claude/settings.json` (Hooks config)
```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${HOME}/.claude/kanban-mcp/hooks/session_start.py"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${HOME}/.claude/kanban-mcp/hooks/stop.py"
          }
        ]
      }
    ]
  }
}
```

## How It Works

- **MCP Server**: Passes `KANBAN_PROJECT_DIR` via env var expansion
- **Hooks**: Read `CLAUDE_PROJECT_DIR` from environment (set by Claude Code)
- **Project ID**: SHA256 hash of directory path (deterministic, same for both)

## CLI Tool

For manual queries or debugging:
```bash
~/kanban_mcp/kanban_cli.py -p /path/to/project context
~/kanban_mcp/kanban_cli.py -p /path/to/project active
~/kanban_mcp/kanban_cli.py -p /path/to/project summary
```

## Web UI

Run the web interface for visual kanban board management:
```bash
python3 ~/kanban_mcp/kanban_web.py --port 5000
```

File structure:
- `kanban_web.py` - Flask application
- `templates/index.html` - Main HTML template
- `static/styles.css` - CSS styles (Material dark theme)
- `static/app.js` - Application JavaScript
- `static/dragdrop.js` - Drag-and-drop functionality

## MCP Tools

- `set_current_project` / `get_current_project` - Project context (optional if env var set)
- `new_item` - Create issue/todo/feature/epic/diary (with optional complexity 1-5, parent_id)
- `list_items` - List with type/status/tag filters (supports AND/OR tag matching)
- `get_item` - Get item details
- `edit_item` - Update title, description, priority, complexity, parent_id
- `advance_status` / `revert_status` / `set_status` - Status workflow
- `close_item` / `delete_item` - Complete/remove items
- `add_update` - Add progress notes
- `get_latest_update` / `get_updates` - View updates
- `project_summary` - Counts by type/status
- `get_active_items` - In-progress items
- `get_todos` - Backlog items
- `add_relationship` / `remove_relationship` / `get_item_relationships` / `get_blocking_items` - Item dependencies
- `list_tags` / `add_tag` / `remove_tag` / `get_item_tags` / `update_tag` / `delete_tag` - Tag management
- `get_status_history` / `get_item_metrics` - Metrics and history tracking
- `get_epic_progress` / `set_parent` / `list_children` - Epic hierarchy management
