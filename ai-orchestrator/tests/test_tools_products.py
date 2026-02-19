import unittest
from unittest.mock import patch
import json

from tool_registry import (
    list_products,
    create_product,
    update_product,
    delete_product,
)

class TestWooCommerceTools(unittest.TestCase):

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_list_products(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "[]"

        result = list_products("nike", per_page=5)

        self.assertEqual(result, "[]")
        mock_run.assert_called_once()
        args = mock_run.call_args[0][2]
        self.assertIn("product", args)
        self.assertIn("list", args)
        self.assertIn("--format=json", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_create_product(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "123"

        result = create_product("nike", "Shoe", "99")

        self.assertIn("123", result)
        args = mock_run.call_args[0][2]
        self.assertIn("create", args)
        self.assertIn("--regular_price=99", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_delete_product(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "Deleted"

        delete_product("nike", 100, force=True)

        args = mock_run.call_args[0][2]
        self.assertIn("--force", args)


if __name__ == "__main__":
    unittest.main()
