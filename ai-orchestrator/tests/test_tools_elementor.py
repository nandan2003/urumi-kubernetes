import unittest
from unittest.mock import patch

from tool_registry import (
    flush_css,
    replace_urls,
    system_info,
    library_sync,
)

class TestElementorTools(unittest.TestCase):

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_flush_css(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        flush_css("nike")
        args = mock_run.call_args[0][2]
        self.assertIn("flush-css", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_replace_urls(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        replace_urls("nike", "a.com", "b.com")
        args = mock_run.call_args[0][2]
        self.assertIn("replace-urls", args)

    @patch("tool_registry.run_wp_cli_command")
    @patch("tool_registry.resolve_store")
    def test_library_sync(self, mock_resolve, mock_run):
        mock_resolve.return_value = ("store-nike", "pod-1")
        library_sync("nike")
        args = mock_run.call_args[0][2]
        self.assertIn("library-sync", args)


if __name__ == "__main__":
    unittest.main()
