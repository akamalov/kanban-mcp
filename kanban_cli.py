#!/usr/bin/env python3
"""
Kanban CLI - Command-line interface for Claude Code hooks.
Shares KanbanDB with the MCP server for consistent data access.
"""

import argparse
import json
import sys
from pathlib import Path

# Import shared database class
from kanban_mcp import KanbanDB
from kanban_export import ExportBuilder, export_to_format


def get_active_items(db: KanbanDB, project_path: str, format: str = "text") -> str:
    """Get items currently in progress."""
    project_id = db.ensure_project(project_path)
    items = db.list_items(project_id=project_id, status_name="in_progress", limit=20)
    
    if format == "json":
        return json.dumps({"items": items, "count": len(items)}, indent=2, default=str)
    
    if not items:
        return ""
    
    lines = ["## Active Items (in_progress)"]
    for item in items:
        lines.append(f"- [{item['type_name']}#{item['id']}] {item['title']} (priority {item['priority']})")
    return "\n".join(lines)


def get_todos(db: KanbanDB, project_path: str, format: str = "text") -> str:
    """Get items in backlog."""
    project_id = db.ensure_project(project_path)
    items = db.list_items(project_id=project_id, status_name="backlog", limit=20)
    
    if format == "json":
        return json.dumps({"items": items, "count": len(items)}, indent=2, default=str)
    
    if not items:
        return ""
    
    lines = ["## Backlog"]
    for item in items:
        lines.append(f"- [{item['type_name']}#{item['id']}] {item['title']} (priority {item['priority']})")
    return "\n".join(lines)


def get_summary(db: KanbanDB, project_path: str, format: str = "text") -> str:
    """Get project summary."""
    project_id = db.ensure_project(project_path)
    summary = db.project_summary(project_id)
    project = db.get_project_by_id(project_id)
    
    if format == "json":
        return json.dumps({"project": project, "summary": summary}, indent=2, default=str)
    
    if not summary:
        return ""
    
    lines = [f"## Project: {project['name'] if project else 'Unknown'}"]
    for type_name, statuses in summary.items():
        status_parts = [f"{status}: {count}" for status, count in statuses.items()]
        lines.append(f"- {type_name}: {', '.join(status_parts)}")
    return "\n".join(lines)


def get_context(db: KanbanDB, project_path: str, format: str = "text") -> str:
    """Get full context for hook injection (active items + summary)."""
    project_id = db.ensure_project(project_path)
    project = db.get_project_by_id(project_id)
    active = db.list_items(project_id=project_id, status_name="in_progress", limit=10)
    summary = db.project_summary(project_id)
    
    if format == "json":
        return json.dumps({
            "project": project,
            "active_items": active,
            "summary": summary
        }, indent=2, default=str)
    
    # Text format for hook injection
    lines = []
    
    if active:
        lines.append(f"[Kanban: {project['name'] if project else 'project'}]")
        lines.append("Active items:")
        for item in active:
            desc = f" - {item['description'][:60]}..." if item.get('description') else ""
            lines.append(f"  • #{item['id']} {item['title']}{desc}")
    
    return "\n".join(lines)


def get_latest_update(db: KanbanDB, project_path: str, format: str = "text") -> str:
    """Get most recent update."""
    project_id = db.ensure_project(project_path)
    update = db.get_latest_update(project_id)

    if format == "json":
        return json.dumps({"update": update}, indent=2, default=str)

    if not update:
        return ""

    return f"Last update: {update['content']}"


def do_search(db: KanbanDB, project_path: str, query: str, limit: int = 20, format: str = "text") -> str:
    """Search items and updates."""
    project_id = db.ensure_project(project_path)
    results = db.search(project_id, query, limit)

    if format == "json":
        return json.dumps(results, indent=2, default=str)

    if results['total_count'] == 0:
        return "No results found"

    lines = [f"## Search results for: {query}"]

    if results['items']:
        lines.append(f"\n### Items ({len(results['items'])})")
        for item in results['items']:
            snippet = f" - {item['snippet'][:50]}..." if item.get('snippet') else ""
            lines.append(f"- [{item['type_name']}#{item['id']}] {item['title']} ({item['status_name']}){snippet}")

    if results['updates']:
        lines.append(f"\n### Updates ({len(results['updates'])})")
        for update in results['updates']:
            snippet = update.get('snippet', '')[:60]
            lines.append(f"- {snippet}...")

    return "\n".join(lines)


def get_children(db: KanbanDB, project_path: str, item_id: int, recursive: bool = False, format: str = "text") -> str:
    """Get children of an item (epic)."""
    if recursive:
        children = db.get_all_descendants(item_id)
    else:
        children = db.get_children(item_id)

    if format == "json":
        return json.dumps({"children": children, "count": len(children)}, indent=2, default=str)

    if not children:
        return f"No children for item #{item_id}"

    # Get item info for header
    item = db.get_item(item_id)
    title = item['title'] if item else 'Unknown'

    lines = [f"## Children of #{item_id}: {title}"]
    for child in children:
        status = child.get('status_name', '')
        lines.append(f"- [{child['type_name']}#{child['id']}] {child['title']} ({status})")

    # Also show progress if it's an epic
    if item and item.get('type_name') == 'epic':
        progress = db.get_epic_progress(item_id)
        lines.append(f"\nProgress: {progress['completed']}/{progress['total']} ({progress['percent']}%)")

    return "\n".join(lines)


def export_data(
    db: KanbanDB,
    project_path: str,
    format: str = "json",
    item_type: str = None,
    status: str = None,
    item_ids: str = None,
    include_tags: bool = True,
    include_relationships: bool = False,
    include_metrics: bool = False,
    include_updates: bool = False,
    include_epic_progress: bool = False,
    detailed: bool = False,
    limit: int = 500,
    output: str = None
) -> str:
    """Export project data in various formats."""
    project_id = db.ensure_project(project_path)

    # Parse item IDs if provided
    parsed_item_ids = None
    if item_ids:
        parsed_item_ids = [int(x.strip()) for x in item_ids.split(',') if x.strip()]

    # Build export data
    builder = ExportBuilder(db, project_id)
    data = builder.build_export_data(
        item_ids=parsed_item_ids,
        item_type=item_type,
        status=status,
        include_tags=include_tags,
        include_relationships=include_relationships,
        include_metrics=include_metrics,
        include_updates=include_updates,
        include_epic_progress=include_epic_progress,
        limit=limit
    )

    # Format output
    content = export_to_format(data, format=format, detailed=detailed)

    # Write to file if output specified
    if output:
        with open(output, 'w', encoding='utf-8') as f:
            f.write(content)
        return f"Exported {len(data.get('items', []))} items to {output}"

    return content


def main():
    parser = argparse.ArgumentParser(
        description="Kanban CLI for Claude Code hooks",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--project", "-p",
        required=True,
        help="Project directory path (usually $PWD)"
    )
    parser.add_argument(
        "--format", "-f",
        choices=["text", "json"],
        default="text",
        help="Output format (default: text)"
    )
    
    subparsers = parser.add_subparsers(dest="command", help="Command to run")
    
    # Commands
    subparsers.add_parser("active", help="Get active (in_progress) items")
    subparsers.add_parser("todos", help="Get backlog items")
    subparsers.add_parser("summary", help="Get project summary")
    subparsers.add_parser("context", help="Get full context for hooks")
    subparsers.add_parser("latest-update", help="Get most recent update")

    # Children command
    children_parser = subparsers.add_parser("children", help="Get children of an item (epic)")
    children_parser.add_argument("item_id", type=int, help="Item ID to get children for")
    children_parser.add_argument("--recursive", "-r", action="store_true", help="Include all descendants")

    # Search command
    search_parser = subparsers.add_parser("search", help="Search items and updates")
    search_parser.add_argument("query", help="Search query")
    search_parser.add_argument("--limit", "-l", type=int, default=20, help="Max results (default: 20)")

    # Export command with additional options
    export_parser = subparsers.add_parser("export", help="Export project data")
    export_parser.add_argument(
        "--format", "-F",
        choices=["json", "yaml", "markdown"],
        default="json",
        help="Output format (default: json)"
    )
    export_parser.add_argument(
        "--type", "-t",
        dest="item_type",
        help="Filter by item type (issue, feature, epic, todo, diary)"
    )
    export_parser.add_argument(
        "--status", "-s",
        help="Filter by status (backlog, todo, in_progress, review, done, closed)"
    )
    export_parser.add_argument(
        "--ids",
        dest="item_ids",
        help="Comma-separated item IDs to export"
    )
    export_parser.add_argument(
        "--no-tags",
        action="store_true",
        help="Exclude tags from export"
    )
    export_parser.add_argument(
        "--relationships",
        action="store_true",
        help="Include relationship data"
    )
    export_parser.add_argument(
        "--metrics",
        action="store_true",
        help="Include metrics data"
    )
    export_parser.add_argument(
        "--updates",
        action="store_true",
        help="Include project updates"
    )
    export_parser.add_argument(
        "--epic-progress",
        action="store_true",
        help="Include epic progress stats"
    )
    export_parser.add_argument(
        "--detailed", "-d",
        action="store_true",
        help="For markdown, show detailed item info instead of tables"
    )
    export_parser.add_argument(
        "--limit", "-l",
        type=int,
        default=500,
        help="Maximum items to export (default: 500)"
    )
    export_parser.add_argument(
        "--output", "-o",
        help="Output file path (prints to stdout if not specified)"
    )
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        sys.exit(1)
    
    db = KanbanDB()
    
    commands = {
        "active": get_active_items,
        "todos": get_todos,
        "summary": get_summary,
        "context": get_context,
        "latest-update": get_latest_update,
    }

    try:
        if args.command == "export":
            # Export command has special arguments
            result = export_data(
                db,
                args.project,
                format=args.format,
                item_type=getattr(args, 'item_type', None),
                status=getattr(args, 'status', None),
                item_ids=getattr(args, 'item_ids', None),
                include_tags=not getattr(args, 'no_tags', False),
                include_relationships=getattr(args, 'relationships', False),
                include_metrics=getattr(args, 'metrics', False),
                include_updates=getattr(args, 'updates', False),
                include_epic_progress=getattr(args, 'epic_progress', False),
                detailed=getattr(args, 'detailed', False),
                limit=getattr(args, 'limit', 500),
                output=getattr(args, 'output', None)
            )
        elif args.command == "children":
            result = get_children(
                db,
                args.project,
                args.item_id,
                recursive=getattr(args, 'recursive', False),
                format=args.format
            )
        elif args.command == "search":
            result = do_search(
                db,
                args.project,
                args.query,
                limit=getattr(args, 'limit', 20),
                format=args.format
            )
        else:
            result = commands[args.command](db, args.project, args.format)

        if result:
            print(result)
    except Exception as e:
        if args.format == "json":
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
