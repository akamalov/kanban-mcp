#!/usr/bin/env python3
"""
Unit tests for Kanban Web UI Flask routes.
Tests define target behavior - written BEFORE implementation (TDD).
"""

import io
import sys
import json
import unittest
from unittest.mock import patch

from tests.test_kanban_mcp import cleanup_test_project


class TestKanbanWebAPI(unittest.TestCase):
    """Test Flask web API routes."""

    @classmethod
    def setUpClass(cls):
        from kanban_mcp.core import KanbanDB
        from kanban_mcp.web import app

        cls.db = KanbanDB()
        cls.app = app
        cls.app.config['TESTING'] = True
        cls.client = cls.app.test_client()
        cls.test_project_path = "/tmp/test-kanban-web"
        cls.test_project_id = cls.db.hash_project_path(cls.test_project_path)

    def setUp(self):
        """Clean state before each test."""
        cleanup_test_project(self.db, self.test_project_path)
        self.db.ensure_project(self.test_project_path, "Test Web Project")
        # Create a test item
        self.test_item_id = self.db.create_item(
            project_id=self.test_project_id,
            type_name="issue",
            title="Test Issue",
            description="Test description",
            priority=2
        )

    def tearDown(self):
        """Clean up after each test."""
        cleanup_test_project(self.db, self.test_project_path)

    # --- Edit Item API Tests ---

    def test_api_edit_item_updates_title(self):
        """POST /api/items/<id> should update item title."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}',
            json={'title': 'Updated Title'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

        # Verify in database
        item = self.db.get_item(self.test_item_id)
        self.assertEqual(item['title'], 'Updated Title')

    def test_api_edit_item_updates_description(self):
        """POST /api/items/<id> should update item description."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}',
            json={'description': 'New description'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

        item = self.db.get_item(self.test_item_id)
        self.assertEqual(item['description'], 'New description')

    def test_api_edit_item_updates_priority(self):
        """POST /api/items/<id> should update item priority."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}',
            json={'priority': 1},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 200)

        item = self.db.get_item(self.test_item_id)
        self.assertEqual(item['priority'], 1)

    def test_api_edit_item_updates_status(self):
        """POST /api/items/<id> should update item status."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}',
            json={'status': 'in_progress'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 200)

        item = self.db.get_item(self.test_item_id)
        self.assertEqual(item['status_name'], 'in_progress')

    def test_api_edit_item_not_found(self):
        """POST /api/items/<id> should return 404 for non-existent item."""
        response = self.client.post(
            '/api/items/99999',
            json={'title': 'New Title'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 404)

    def test_api_edit_item_invalid_status(self):
        """POST /api/items/<id> should return error for invalid status."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}',
            json={'status': 'invalid_status'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 400)

    # --- Get Item API Tests ---

    def test_api_get_item(self):
        """GET /api/items/<id> should return item details."""
        response = self.client.get(f'/api/items/{self.test_item_id}')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data['id'], self.test_item_id)
        self.assertEqual(data['title'], 'Test Issue')
        self.assertEqual(data['type'], 'issue')

    def test_api_get_item_not_found(self):
        """GET /api/items/<id> should return 404 for non-existent item."""
        response = self.client.get('/api/items/99999')
        self.assertEqual(response.status_code, 404)

    # --- Create Update API Tests ---

    def test_api_create_update_unlinked(self):
        """POST /api/updates should create unlinked update and persist it."""
        response = self.client.post(
            '/api/updates',
            json={
                'project_id': self.test_project_id,
                'content': 'Test update content'
            },
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 201)
        data = response.get_json()
        self.assertTrue(data['success'])
        self.assertIn('update_id', data)

        # Verify update actually persisted in DB (#8233)
        with self.db._db_cursor(dictionary=True) as cursor:
            cursor.execute("SELECT content FROM updates WHERE id = %s", (data['update_id'],))
            row = cursor.fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row['content'], 'Test update content')

    def test_api_create_update_linked_to_item(self):
        """POST /api/updates should create update linked to items."""
        response = self.client.post(
            '/api/updates',
            json={
                'project_id': self.test_project_id,
                'content': 'Update linked to item',
                'item_ids': [self.test_item_id]
            },
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 201)
        data = response.get_json()
        self.assertTrue(data['success'])

        # Verify the link actually exists in DB (#8233)
        with self.db._db_cursor(dictionary=True) as cursor:
            cursor.execute(
                "SELECT item_id FROM update_items WHERE update_id = %s",
                (data['update_id'],)
            )
            row = cursor.fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row['item_id'], self.test_item_id)

    def test_api_create_update_missing_content(self):
        """POST /api/updates should return 400 if content missing."""
        response = self.client.post(
            '/api/updates',
            json={'project_id': self.test_project_id},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 400)

    # --- Set Status API Tests ---

    def test_api_set_status(self):
        """POST /api/items/<id>/status should change item status."""
        response = self.client.post(
            f'/api/items/{self.test_item_id}/status',
            json={'status': 'todo'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

        item = self.db.get_item(self.test_item_id)
        self.assertEqual(item['status_name'], 'todo')

    def test_api_set_status_blocked_item(self):
        """POST /api/items/<id>/status should fail for blocked item going to done."""
        # Create a blocker item
        blocker_id = self.db.create_item(
            project_id=self.test_project_id,
            type_name="issue",
            title="Blocker"
        )
        # Create blocking relationship
        self.db.add_relationship(blocker_id, self.test_item_id, 'blocks')

        # Try to move blocked item to done
        response = self.client.post(
            f'/api/items/{self.test_item_id}/status',
            json={'status': 'done'},
            content_type='application/json'
        )
        self.assertEqual(response.status_code, 400)
        data = response.get_json()
        self.assertFalse(data['success'])
        self.assertIn('blocked', data.get('message', '').lower())

    # --- Delete Item API Tests ---

    def test_api_delete_item(self):
        """DELETE /api/items/<id> should delete the item."""
        response = self.client.delete(f'/api/items/{self.test_item_id}')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

        # Verify item is gone
        item = self.db.get_item(self.test_item_id)
        self.assertIsNone(item)

    def test_api_delete_item_not_found(self):
        """DELETE /api/items/<id> should return 404 for non-existent item."""
        response = self.client.delete('/api/items/99999')
        self.assertEqual(response.status_code, 404)

    # --- Delete Project API Tests ---

    def test_api_delete_project(self):
        """DELETE /api/projects/<id> should delete project and all data."""
        response = self.client.delete(f'/api/projects/{self.test_project_id}')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

        # Verify project is gone
        with self.db._db_cursor(dictionary=True) as cursor:
            cursor.execute("SELECT id FROM projects WHERE id = %s", (self.test_project_id,))
            self.assertIsNone(cursor.fetchone())

    def test_api_delete_project_not_found(self):
        """DELETE /api/projects/<id> should return 404 for non-existent project."""
        response = self.client.delete('/api/projects/nonexistent1234')
        self.assertEqual(response.status_code, 404)

    # --- Get Items for Dropdown API Tests ---

    def test_api_get_items_list(self):
        """GET /api/items?project=X should return items list for dropdown."""
        response = self.client.get(f'/api/items?project={self.test_project_id}')
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertIn('items', data)
        self.assertEqual(len(data['items']), 1)
        self.assertEqual(data['items'][0]['title'], 'Test Issue')


class TestBlockedCardRendering(unittest.TestCase):
    """Tests for #21042 — blocked cards should become unblocked when blockers complete."""

    @classmethod
    def setUpClass(cls):
        from kanban_mcp.core import KanbanDB
        from kanban_mcp.web import app

        cls.db = KanbanDB()
        cls.app = app
        cls.app.config['TESTING'] = True
        cls.client = cls.app.test_client()
        cls.test_project_path = "/tmp/test-kanban-web-blocked"
        cls.test_project_id = cls.db.hash_project_path(cls.test_project_path)

    def setUp(self):
        cleanup_test_project(self.db, self.test_project_path)
        self.db.ensure_project(self.test_project_path, "Test Blocked Project")
        # Create blocker and blocked items
        self.blocker_id = self.db.create_item(
            project_id=self.test_project_id,
            type_name="issue",
            title="Blocker Issue"
        )
        self.blocked_id = self.db.create_item(
            project_id=self.test_project_id,
            type_name="feature",
            title="Blocked Feature"
        )
        self.db.add_relationship(self.blocker_id, self.blocked_id, 'blocks')

    def tearDown(self):
        cleanup_test_project(self.db, self.test_project_path)

    def test_active_blocker_marks_card_blocked(self):
        """Card should have data-blocked=true when blocker is in backlog."""
        response = self.client.get(f'/?project={self.test_project_id}')
        self.assertEqual(response.status_code, 200)
        html = response.data.decode()
        # Find the blocked card and check its data-blocked attribute
        # The blocked item should have data-blocked="true"
        self.assertIn(f'data-item-id="{self.blocked_id}"', html)
        # Extract the card div for the blocked item
        import re
        card_match = re.search(
            rf'<div class="card[^"]*"[^>]*data-item-id="{self.blocked_id}"[^>]*>',
            html
        )
        self.assertIsNotNone(card_match, "Blocked item card should exist in HTML")
        card_tag = card_match.group(0)
        self.assertIn('data-blocked="true"', card_tag,
                       "Card should be blocked when blocker is active")

    def test_completed_blocker_unblocks_card(self):
        """Card should have data-blocked=false when all blockers are done (#21042)."""
        # Move blocker to done
        self.db.set_status(self.blocker_id, 'done')

        response = self.client.get(f'/?project={self.test_project_id}')
        self.assertEqual(response.status_code, 200)
        html = response.data.decode()

        import re
        card_match = re.search(
            rf'<div class="card[^"]*"[^>]*data-item-id="{self.blocked_id}"[^>]*>',
            html
        )
        self.assertIsNotNone(card_match, "Blocked item card should exist in HTML")
        card_tag = card_match.group(0)
        self.assertIn('data-blocked="false"', card_tag,
                       "Card should NOT be blocked when all blockers are done")
        self.assertIn('draggable="true"', card_tag,
                       "Card should be draggable when unblocked")

    def test_closed_blocker_unblocks_card(self):
        """Card should have data-blocked=false when all blockers are closed."""
        self.db.set_status(self.blocker_id, 'closed')

        response = self.client.get(f'/?project={self.test_project_id}')
        html = response.data.decode()

        import re
        card_match = re.search(
            rf'<div class="card[^"]*"[^>]*data-item-id="{self.blocked_id}"[^>]*>',
            html
        )
        self.assertIsNotNone(card_match)
        card_tag = card_match.group(0)
        self.assertIn('data-blocked="false"', card_tag)

    def test_partial_blockers_still_blocked(self):
        """Card should remain blocked if only some blockers are done."""
        # Add a second blocker
        blocker2_id = self.db.create_item(
            project_id=self.test_project_id,
            type_name="issue",
            title="Second Blocker"
        )
        self.db.add_relationship(blocker2_id, self.blocked_id, 'blocks')
        # Complete only the first blocker
        self.db.set_status(self.blocker_id, 'done')

        response = self.client.get(f'/?project={self.test_project_id}')
        html = response.data.decode()

        import re
        card_match = re.search(
            rf'<div class="card[^"]*"[^>]*data-item-id="{self.blocked_id}"[^>]*>',
            html
        )
        self.assertIsNotNone(card_match)
        card_tag = card_match.group(0)
        self.assertIn('data-blocked="true"', card_tag,
                       "Card should stay blocked when some blockers are still active")


class TestConnectionLeaks(unittest.TestCase):
    """Tests for #8222 — no connection leaks from raw cursor usage."""

    @classmethod
    def setUpClass(cls):
        from kanban_mcp.core import KanbanDB
        from kanban_mcp.web import app

        cls.db = KanbanDB()
        cls.app = app
        cls.app.config['TESTING'] = True
        cls.client = cls.app.test_client()
        cls.test_project_path = "/tmp/test-kanban-web-leak"
        cls.test_project_id = cls.db.hash_project_path(cls.test_project_path)

    def setUp(self):
        cleanup_test_project(self.db, self.test_project_path)
        self.db.ensure_project(self.test_project_path, "Test Leak Project")
        self.db.create_item(self.test_project_id, 'issue', 'Leak test item')

    def tearDown(self):
        cleanup_test_project(self.db, self.test_project_path)

    def test_api_list_items_no_leak(self):
        """Calling api_list_items repeatedly should not exhaust pool."""
        for _ in range(20):
            response = self.client.get(f'/api/items?project={self.test_project_id}')
            self.assertEqual(response.status_code, 200)

    def test_index_page_no_leak(self):
        """Loading index page repeatedly should not exhaust pool."""
        for _ in range(20):
            response = self.client.get(f'/?project={self.test_project_id}')
            self.assertEqual(response.status_code, 200)

    def test_delete_nonexistent_project(self):
        """Deleting non-existent project should return 404, not crash."""
        response = self.client.delete('/api/projects/nonexistent1234')
        self.assertEqual(response.status_code, 404)


class TestHostBindingWarning(unittest.TestCase):
    """Tests for #8225 — warning when binding to public interfaces."""

    def _simulate_main_block(self, host, debug=False):
        """Simulate the kanban_web __main__ block logic and capture stderr."""
        captured = io.StringIO()
        if host in ('0.0.0.0', '::'):
            print(
                f"WARNING: Binding to {host} exposes this server to the network. "
                "There is no authentication — anyone on your network can read/modify data.",
                file=captured
            )
            if debug:
                print(
                    "WARNING: Debug mode with a public binding is especially dangerous — "
                    "Werkzeug's debugger allows arbitrary code execution.",
                    file=captured
                )
        return captured.getvalue()

    def test_host_0000_warning(self):
        output = self._simulate_main_block('0.0.0.0')
        self.assertIn('WARNING', output)
        self.assertIn('0.0.0.0', output)

    def test_host_ipv6_any_warning(self):
        output = self._simulate_main_block('::')
        self.assertIn('WARNING', output)

    def test_host_localhost_no_warning(self):
        output = self._simulate_main_block('127.0.0.1')
        self.assertEqual(output, '')

    def test_host_debug_with_0000_extra_warning(self):
        output = self._simulate_main_block('0.0.0.0', debug=True)
        self.assertIn('debug', output.lower())
        self.assertIn('code execution', output.lower())


if __name__ == '__main__':
    unittest.main()
