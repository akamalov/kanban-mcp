#!/usr/bin/env python3
"""
Unit tests for kanban-setup console script.
Tests non-DB logic: arg parsing, migration discovery, password gen, .env writing.
"""

import os
import sys
import secrets
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock


class TestArgParsing(unittest.TestCase):
    """Test argument parsing for interactive vs auto mode."""

    def setUp(self):
        from kanban_mcp.setup import build_parser
        self.parser = build_parser()

    def test_default_is_interactive(self):
        args = self.parser.parse_args([])
        self.assertFalse(args.auto)

    def test_auto_flag(self):
        args = self.parser.parse_args(["--auto"])
        self.assertTrue(args.auto)

    def test_with_semantic_flag(self):
        args = self.parser.parse_args(["--with-semantic"])
        self.assertTrue(args.with_semantic)

    def test_all_db_args(self):
        args = self.parser.parse_args([
            "--db-name", "mydb",
            "--db-user", "myuser",
            "--db-password", "mypass",
            "--db-host", "remotehost",
            "--mysql-root-user", "admin",
            "--mysql-root-password", "rootpass",
        ])
        self.assertEqual(args.db_name, "mydb")
        self.assertEqual(args.db_user, "myuser")
        self.assertEqual(args.db_password, "mypass")
        self.assertEqual(args.db_host, "remotehost")
        self.assertEqual(args.mysql_root_user, "admin")
        self.assertEqual(args.mysql_root_password, "rootpass")

    def test_defaults(self):
        args = self.parser.parse_args([])
        self.assertIsNone(args.db_name)
        self.assertIsNone(args.db_user)
        self.assertIsNone(args.db_password)
        self.assertIsNone(args.db_host)
        self.assertIsNone(args.mysql_root_user)
        self.assertIsNone(args.mysql_root_password)


class TestPasswordGeneration(unittest.TestCase):
    """Test password auto-generation."""

    def test_generate_password_returns_string(self):
        from kanban_mcp.setup import generate_password
        pw = generate_password()
        self.assertIsInstance(pw, str)

    def test_generate_password_sufficient_length(self):
        from kanban_mcp.setup import generate_password
        pw = generate_password()
        self.assertGreaterEqual(len(pw), 16)

    def test_generate_password_unique(self):
        from kanban_mcp.setup import generate_password
        passwords = {generate_password() for _ in range(10)}
        self.assertEqual(len(passwords), 10)


class TestMigrationDiscovery(unittest.TestCase):
    """Test finding migration SQL files."""

    def test_find_migrations_from_local_repo(self):
        from kanban_mcp.setup import find_migrations_dir
        # When run from the repo root, should find kanban_mcp/migrations
        repo_root = Path(__file__).parent.parent
        migrations_dir = repo_root / "kanban_mcp" / "migrations"
        if migrations_dir.exists():
            result = find_migrations_dir()
            self.assertIsNotNone(result)
            self.assertTrue(Path(result).is_dir())

    def test_find_migrations_returns_dir_with_sql_files(self):
        from kanban_mcp.setup import find_migrations_dir
        result = find_migrations_dir()
        if result is not None:
            sql_files = sorted(Path(result).glob("0*.sql"))
            self.assertGreater(len(sql_files), 0)

    def test_get_migration_files_sorted(self):
        from kanban_mcp.setup import get_migration_files
        files = get_migration_files()
        if files:
            names = [f.name for f in files]
            self.assertEqual(names, sorted(names))
            self.assertTrue(all(f.suffix == ".sql" for f in files))


class TestEnvFileWriting(unittest.TestCase):
    """Test .env file generation."""

    def test_write_env_file(self):
        from kanban_mcp.setup import write_env_file
        with tempfile.TemporaryDirectory() as tmpdir:
            env_path = os.path.join(tmpdir, ".env")
            write_env_file(
                env_path,
                db_host="localhost",
                db_user="kanban",
                db_password="secret123",
                db_name="kanban",
            )
            self.assertTrue(os.path.exists(env_path))
            content = Path(env_path).read_text()
            self.assertIn("KANBAN_DB_HOST=localhost", content)
            self.assertIn("KANBAN_DB_USER=kanban", content)
            self.assertIn("KANBAN_DB_PASSWORD=secret123", content)
            self.assertIn("KANBAN_DB_NAME=kanban", content)

    def test_write_env_file_does_not_have_trailing_spaces(self):
        from kanban_mcp.setup import write_env_file
        with tempfile.TemporaryDirectory() as tmpdir:
            env_path = os.path.join(tmpdir, ".env")
            write_env_file(env_path, "localhost", "kanban", "pw", "kanban")
            for line in Path(env_path).read_text().splitlines():
                if line.strip():
                    self.assertEqual(line, line.rstrip())


class TestConfigGathering(unittest.TestCase):
    """Test config resolution from args, env vars, and defaults."""

    def test_auto_mode_uses_env_vars(self):
        from kanban_mcp.setup import resolve_config, build_parser
        parser = build_parser()
        args = parser.parse_args(["--auto"])
        env = {
            "KANBAN_DB_NAME": "envdb",
            "KANBAN_DB_USER": "envuser",
            "KANBAN_DB_PASSWORD": "envpass",
            "KANBAN_DB_HOST": "envhost",
            "MYSQL_ROOT_USER": "envroot",
            "MYSQL_ROOT_PASSWORD": "envrootpw",
        }
        with patch.dict(os.environ, env, clear=False):
            config = resolve_config(args)
        self.assertEqual(config["db_name"], "envdb")
        self.assertEqual(config["db_user"], "envuser")
        self.assertEqual(config["db_password"], "envpass")
        self.assertEqual(config["db_host"], "envhost")
        self.assertEqual(config["mysql_root_user"], "envroot")
        self.assertEqual(config["mysql_root_password"], "envrootpw")

    def test_auto_mode_cli_args_override_env(self):
        from kanban_mcp.setup import resolve_config, build_parser
        parser = build_parser()
        args = parser.parse_args([
            "--auto",
            "--db-name", "clidb",
            "--db-user", "cliuser",
        ])
        env = {
            "KANBAN_DB_NAME": "envdb",
            "KANBAN_DB_USER": "envuser",
        }
        with patch.dict(os.environ, env, clear=False):
            config = resolve_config(args)
        self.assertEqual(config["db_name"], "clidb")
        self.assertEqual(config["db_user"], "cliuser")

    def test_auto_mode_defaults(self):
        from kanban_mcp.setup import resolve_config, build_parser
        parser = build_parser()
        args = parser.parse_args(["--auto"])
        # Clear relevant env vars
        env_clear = {
            "KANBAN_DB_NAME": "",
            "KANBAN_DB_USER": "",
            "KANBAN_DB_PASSWORD": "",
            "KANBAN_DB_HOST": "",
            "MYSQL_ROOT_USER": "",
            "MYSQL_ROOT_PASSWORD": "",
        }
        with patch.dict(os.environ, env_clear, clear=False):
            # Remove the keys entirely
            for k in env_clear:
                os.environ.pop(k, None)
            config = resolve_config(args)
        self.assertEqual(config["db_name"], "kanban")
        self.assertEqual(config["db_user"], "kanban")
        self.assertEqual(config["db_host"], "localhost")
        self.assertEqual(config["mysql_root_user"], "root")
        # Password should be auto-generated
        self.assertIsNotNone(config["db_password"])
        self.assertGreaterEqual(len(config["db_password"]), 16)


class TestGetConfigDir(unittest.TestCase):
    """Test the shared get_config_dir() helper."""

    def test_linux_default(self):
        from kanban_mcp.core import get_config_dir
        with patch("sys.platform", "linux"), \
             patch.dict(os.environ, {}, clear=False):
            os.environ.pop("XDG_CONFIG_HOME", None)
            result = get_config_dir()
            self.assertEqual(result, Path.home() / ".config" / "kanban-mcp")

    def test_linux_xdg_override(self):
        from kanban_mcp.core import get_config_dir
        with patch("sys.platform", "linux"), \
             patch.dict(os.environ, {"XDG_CONFIG_HOME": "/tmp/xdg"}, clear=False):
            result = get_config_dir()
            self.assertEqual(result, Path("/tmp/xdg/kanban-mcp"))

    def test_windows(self):
        from kanban_mcp.core import get_config_dir
        with patch("sys.platform", "win32"), \
             patch.dict(os.environ, {"APPDATA": "C:\\Users\\test\\AppData\\Roaming"}, clear=False):
            result = get_config_dir()
            # On Linux, Path uses forward slashes; just check the components
            self.assertEqual(result.name, "kanban-mcp")
            self.assertTrue(str(result).startswith("C:"))

    def test_returns_path_object(self):
        from kanban_mcp.core import get_config_dir
        result = get_config_dir()
        self.assertIsInstance(result, Path)


class TestHandleEnvFileConfigDir(unittest.TestCase):
    """Test that _handle_env_file writes to the config dir, not CWD."""

    def test_writes_to_config_dir(self):
        from kanban_mcp.setup import _handle_env_file
        config = {
            "db_host": "localhost",
            "db_user": "kanban",
            "db_password": "secret",
            "db_name": "kanban",
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            config_dir = Path(tmpdir) / "kanban-mcp"
            with patch("kanban_mcp.core.get_config_dir", return_value=config_dir):
                _handle_env_file(config, auto=True)
            env_path = config_dir / ".env"
            self.assertTrue(env_path.exists())
            content = env_path.read_text()
            self.assertIn("KANBAN_DB_PASSWORD=secret", content)

    def test_does_not_write_to_cwd(self):
        from kanban_mcp.setup import _handle_env_file
        config = {
            "db_host": "localhost",
            "db_user": "kanban",
            "db_password": "secret",
            "db_name": "kanban",
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            config_dir = Path(tmpdir) / "kanban-mcp"
            cwd_env = Path(tmpdir) / "cwd" / ".env"
            with patch("kanban_mcp.core.get_config_dir", return_value=config_dir), \
                 patch("os.getcwd", return_value=str(Path(tmpdir) / "cwd")):
                _handle_env_file(config, auto=True)
            self.assertFalse(cwd_env.exists())

    def test_creates_config_dir_if_missing(self):
        from kanban_mcp.setup import _handle_env_file
        config = {
            "db_host": "localhost",
            "db_user": "kanban",
            "db_password": "secret",
            "db_name": "kanban",
        }
        with tempfile.TemporaryDirectory() as tmpdir:
            config_dir = Path(tmpdir) / "deep" / "nested" / "kanban-mcp"
            with patch("kanban_mcp.core.get_config_dir", return_value=config_dir):
                _handle_env_file(config, auto=True)
            self.assertTrue(config_dir.exists())
            self.assertTrue((config_dir / ".env").exists())


class TestMcpConfigOutput(unittest.TestCase):
    """Test the MCP config JSON output helper."""

    def test_mcp_config_json(self):
        import json
        from kanban_mcp.setup import mcp_config_json
        result = mcp_config_json("localhost", "kanban", "pw123", "kanban")
        parsed = json.loads(result)
        self.assertIn("mcpServers", parsed)
        self.assertEqual(
            parsed["mcpServers"]["kanban"]["env"]["KANBAN_DB_PASSWORD"],
            "pw123",
        )


if __name__ == "__main__":
    unittest.main()
