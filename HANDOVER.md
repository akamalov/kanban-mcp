# HANDOVER

## Last Session (2026-02-22)

### Completed
**Fixed all 15 audit issues (#8219-#8233)** from the codebase audit (#7539):

1. **Migration 004** — Added ON DELETE CASCADE to items.project_id and updates.project_id FKs. Indexes on item_relationships(target_item_id) and update_items(item_id) already existed.
2. **Credential hardening (#8219)** — Removed hardcoded DB defaults; raises ValueError listing missing env vars. Added dotenv loading from .env file.
3. **Embedding logging (#8224)** — Extracted `_safe_embedding_op()` helper replacing 6 bare try/except blocks with debug-level logging.
4. **Pool exhaustion (#8223)** — Extracted `_rebuild_source_type()` helper that fetches IDs then closes cursor before processing.
5. **Cursor leaks (#8222)** — Replaced all 5 `_get_connection()` calls in kanban_web.py with `_db_cursor()` context manager.
6. **Host warning (#8225)** — Added stderr warning when binding to 0.0.0.0 or :: (especially with debug mode).
7. **Delete simplification** — `api_delete_project` now uses CASCADE, only manually deletes embeddings.
8. **Timeline parsing (#8227)** — Safe GROUP_CONCAT parsing handling empty/null/whitespace/non-numeric values.
9. **CLI validation (#8228)** — Wrapped int() parsing in try/except with clear error message.
10. **Null check (#8229)** — Added defensive null check in `_get_next_tag_color`.
11. **Dead code (#8231)** — Removed unused `escapeHtml()` from app.js.
12. **Migration comments (#8232)** — Fixed hardcoded credentials in migration file comments.
13. **Test assertions (#8233)** — Strengthened web update tests to verify DB persistence.
14. **Test cleanup (#8226)** — Fixed cleanup_test_project to delete item_relationships and use _db_cursor.
15. **Test pool exhaustion fix** — Moved KanbanDB/KanbanMCPServer creation to setUpClass, added env-configurable pool_size, unique pool names per instance. Tests went from 201 pass/46 error to 361 pass/0 error.

Also added: tests/conftest.py (test env config), .env file support via python-dotenv.

### Test Results
- 361 passed, 0 failed, 0 errors (excluding optional onnxruntime-dependent embedding tests)
- 17 embedding test failures are from missing onnxruntime in dev environment (optional dependency)

## Next Session

**Test Docker setup (#7535)** — Docker files were created in a previous session but never tested. Need a Docker-capable environment to:
- `docker compose up -d` and verify MySQL + web UI start
- Verify migrations run on first start
- Test MCP server connectivity from Docker
- Fix any issues found

### Remaining open-source epic (#7532) children after audit:
- #7535 Docker and docker-compose setup (untested)
- #7538 Manual install documentation
- #7537 pip packaging with pyproject.toml
