"""Test configuration - sets DB credentials for test environment."""
import os

# Set test database credentials if not already set.
# These are the development defaults; CI/Docker should set real values.
_test_defaults = {
    "KANBAN_DB_HOST": "localhost",
    "KANBAN_DB_USER": "claude",
    "KANBAN_DB_PASSWORD": "claude_code_password",
    "KANBAN_DB_NAME": "claude_code_kanban",
    "KANBAN_DB_POOL_SIZE": "2",
}

for key, value in _test_defaults.items():
    if not os.environ.get(key):
        os.environ[key] = value
