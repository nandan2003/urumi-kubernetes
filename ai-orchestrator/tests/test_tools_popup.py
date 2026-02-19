import unittest
from unittest.mock import patch
import json

from tool_registry import (
    create_popup,
    update_popup,
    delete_popup,
    set_popup_settings,
)

class TestPopupTools(unittest.TestCase):

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_create_popup(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "101"

        create_popup("nike", "Sale", "Big Discount")

        args = mock_run.call_args[0][2]
        self.assertIn("--post_type=popup", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_update_popup(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "Updated"

        update_popup(store_name="nike", popup_id=10, title="New")

        args = mock_run.call_args[0][2]
        self.assertIn("update", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_set_popup_settings(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        mock_run.return_value = "{}"

        set_popup_settings("nike", 10, {"triggers": []})

        self.assertTrue(mock_run.called)


if __name__ == "__main__":
    unittest.main()
