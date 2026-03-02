# HANDOVER

## Last Session (2026-02-28)

### Completed

**Docker setup for open-source release (#7535)** — Full Docker integration into install scripts:
- `install.sh` rewritten: `--docker` and `--db-host HOST` flags, MySQL reachability detection (mysqladmin/mysql/nc/dev-tcp fallbacks), Docker availability check, interactive 3-way menu (local/remote/Docker), downloads Docker files from GitHub for standalone use, pipx auto-install
- `install.ps1` mirrors all install.sh changes for Windows PowerShell (`-Docker`, `-DbHost`, TCP connection check via TcpClient, `Invoke-WebRequest` for downloads)
- `docker-compose.yml` parameterised with `${VAR:-default}` env var substitution for all credentials
- `.dockerignore` added `dist/`, `*.egg-info/`, `.venv/`, `build/`
- `README.md` restructured: Quick Start one-liners (`curl | bash` / `irm | iex`), separate Prerequisites section, Installation section explains install script as primary path with all flag variants
- `Dockerfile` switched from Flask dev server (`kanban-web`) to `gunicorn -b 0.0.0.0:5000 kanban_mcp.web:app` for production use

**Blocked items bug fix (#21042)** — Web UI prevented dragging cards even when all blockers were done/closed:
- Root cause: `get_all_relationships()` in `web.py` didn't include blocker status; template set `data-blocked="true"` for any item with blocking relationships regardless of blocker state
- Fix: joined statuses table in query, added `status` field to `blocked_by` entries, template now filters with `rejectattr('status', 'in', ['done', 'closed'])`
- 4 new tests in `TestBlockedCardRendering`: active blocker, done blocker, closed blocker, partial blockers

**Item #7535 advanced** from backlog to todo during debugging (was stuck due to the #21042 bug itself).

### Decisions Made This Session
- **Gunicorn over nginx/apache in Docker** — gunicorn is sufficient for a single-user kanban board, no need for a reverse proxy. Installed only in the container (`pip install gunicorn` in Dockerfile), not as a package dependency.
- **Install scripts as primary entry point** — `install.sh` and `install.ps1` are the single entry points that handle everything (pipx, MySQL detection, Docker, .env). Docker is one option within the script, not a separate install path.
- **Docker files downloaded from GitHub** — install scripts download `docker-compose.yml`, `Dockerfile`, `pyproject.toml`, and migrations into `~/.config/kanban-mcp/docker/` so they work standalone without cloning the repo.
- **Blocked status based on active blockers only** — `is_blocked` in web UI now checks blocker status (done/closed = resolved), matching the server-side `get_blocking_items()` behavior.

### Environment State
- **Branch**: `rebase-clean` — uncommitted changes from this and previous sessions
- **Tests**: `python3.13 -m pytest tests/ -v` — 388 pass (384 original + 4 new)
- **Still needs**: commit all work, tag, publish to PyPI

## Next Session

### Primary: Consolidate timeline and updates (#7540)

**Read the plan document first:** There is no separate plan doc yet — this needs planning in the next session via plan mode.

**Issue description:** Current UX has two separate FABs (Updates and Timeline), timeline doesn't show full update text, updates panel is redundant and doesn't show status changes/decisions/commits. Consolidate into a single panel that replaces both drawers. The timeline view should be the canonical activity view with full update content, status changes, decisions, and commits. Remove the separate updates drawer and FAB.

**Key files to explore:**
- `kanban_mcp/static/timeline.js` — current timeline drawer logic
- `kanban_mcp/static/app.js` — updates drawer logic, FAB buttons
- `kanban_mcp/templates/index.html` — drawer markup, FAB markup
- `kanban_mcp/static/styles.css` — drawer/FAB styles
- `kanban_mcp/web.py` — API endpoints for timeline and updates data

**Approach considerations:**
- Single unified activity panel replaces both drawers
- Timeline entries should show full update content (not truncated)
- Must still support creating new updates from the panel
- Status changes, decisions, commits, and updates all in one chronological view
- Consider whether it's a slide-out drawer or a different UI pattern

### Still TODO
- Commit all outstanding work and tag release
- Force-push rebase-clean to main
- Publish updated version to PyPI
- #7535 Docker setup — code is done, needs user testing
- #21042 Blocked items bug — code is done, needs user testing in browser
